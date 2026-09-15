# headscale Helm chart

A Helm chart for running your own [Headscale](https://github.com/juanfont/headscale)
(self-hosted Tailscale control server), **always as an HA StatefulSet** (`ha.replicas` pods, 2 by default)
with Consul-driven leader election and an Envoy sidecar mesh for traffic
routing. No `hashicorp/consul` chart dependency, no external load
balancer in front of the StatefulSet - everything needed lives in this
one chart.

There is no single-instance mode. If that's what you want, this probably
isn't the right chart for you - the whole design (Consul, Envoy, the
supervisor script) exists specifically to make active/standby work across pods.

## Table of contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Database](#database)
- [Secrets you need to create yourself](#secrets-you-need-to-create-yourself)
- [DERP](#derp)
- [ACL / policy](#acl--policy)
- [DNS](#dns)
- [Consul ACL](#consul-acl-haconsulacl)
- [extraEnv / secretsEnv](#extraenv--secretsenv)
- [extraManifests](#extramanifests)
- [Ingress](#ingress)
- [Known limitations](#known-limitations)

## How it works

- **A lightweight, self-hosted Consul server cluster** (`ha.consul.*`) -
  the official `hashicorp/consul` container image, deployed directly as a
  `StatefulSet` by this chart. Server-only, 3 replicas by default (odd
  number required for Raft quorum - the chart fails fast if you set an
  even number). No gossip encryption or TLS between agents by default;
  `ha.consul.acl.enabled` adds basic token auth (see below).
- **A `consul-agent` sidecar** in every headscale pod: races the other
  pods for a Consul KV lock (`headscale/leader`) to decide who's active;
  polls the local headscale process's own `/health` over loopback and
  releases the lock the instant it stops responding (self-fencing);
  publishes the current leader's pod IP and pod name to Consul KV.
- **An `envoy` sidecar** in every headscale pod, listening on the exact
  ports the Service exposes (`service.httpPort`/`grpcPort`) and forwarding
  every connection to whichever pod currently holds the lock - locally,
  or over the pod network to a sibling. The Kubernetes Service and any
  Ingress in front of it never change; the routing intelligence lives
  entirely inside the pods, via `HttpConnectionManager` with access
  logging to stdout.
- **The headscale container itself runs a small supervisor script**
  instead of a bare `headscale serve`: it starts the real process only
  once its sidecar has marked the pod leader, and stops it the instant
  that stops being true. Headscale only reads DB state at process start,
  so becoming leader always means a fresh process start, never resuming a
  paused one.
- **No `kubectl exec`/Job dance for the one thing that must happen at
  deploy time** - see [ACL / policy](#acl--policy) for how the
  headscale-pf API key gets provisioned entirely from inside the leader
  pod.

## Requirements

- `image.repository`/`image.tag` must point at an image **with a shell**
  (`/bin/sh`) - the default `headscale/headscale` image ships none at
  all, and the HA start/stop supervisor script needs one. The chart fails
  fast at template time unless "alpine" appears in either the repository
  or the tag, as a sanity check.
- PostgreSQL - either the bundled one (`postgresql.enabled: true`) or an
  external instance. No sqlite support; a local-file database can't be
  shared across HA pods.
- A `noise_private.key` you generated yourself (`noisePrivateKey.value` or
  `.existingSecret`).
- A DERP source - `headscale.derp.urls` or `headscale.derp.customMap`
  (see [DERP](#derp)); the chart refuses to silently default to
  Tailscale's public relays.

## Quick start

```bash
# Generate a noise key yourself - the chart doesn't do this for you
openssl rand -hex 32 | tr -d '\n' > /tmp/noise.key

helm install headscale ./headscale \
  --set headscale.serverUrl=https://headscale.example.com \
  --set-file noisePrivateKey.value=/tmp/noise.key \
  --set headscale.derp.urls[0]=https://controlplane.tailscale.com/derpmap/default \
  --set postgresql.enabled=true \
  --set database.postgres.password=CHANGE_ME
```

This uses the bundled single-instance PostgreSQL to keep the example
short (see [Database](#database) for pointing at an external instance
instead), and Tailscale's own public DERP map to keep the DERP example
short (see [DERP](#derp) for running your own).

## Database

Always PostgreSQL, one of two ways:

**Bundled** (`postgresql.enabled: true`) - a single-instance PostgreSQL
`StatefulSet` on its own PVC, deployed right alongside headscale.
**Not highly available** (single pod, single PVC) - a convenience option
for small/medium deployments, not a replacement for a managed database in
production. `database.postgres.host`/`port` are filled in automatically;
`database.postgres.user`/`name`/`password` (or `existingSecret`) are
reused to configure the bundled server itself, so there's one source of
truth for credentials.

**External** - leave `postgresql.enabled: false` and set
`database.postgres.host` (and `existingSecret`, if applicable) yourself.

The password is never written to a ConfigMap - it's passed via the
`HEADSCALE_DATABASE_POSTGRES_PASS` environment variable (note: `PASS`,
not `PASSWORD` - that's the actual field name headscale's config schema
uses), sourced from a Secret.

## Secrets you need to create yourself

This chart does not generate any random secrets on your behalf - GitOps
tools like Argo CD can't track resources created out-of-band by a Job, so
that's not a good fit here (see the headscale-pf API key note below for
the one case that's unavoidably deploy-time). Anything that *can* be
generated offline, generate it yourself and feed it in:

| Secret | Generate with | Wire it in via |
|---|---|---|
| `noise_private.key` | `openssl rand -hex 32` | `noisePrivateKey.value` or `.existingSecret` |
| Consul ACL token | `uuidgen` | `ha.consul.acl.token.value` or `.existingSecret` |
| Postgres password | your usual secret tooling | `database.postgres.password` or `.existingSecret` |
| headscale-pf source token (Authentik etc.) | issued by that system | `acl.sync.source.token` or `.existingSecret` |
| headscale-pf API key | **can't** be pre-generated - see below | provisioned automatically into Consul KV, or `acl.sync.headscale.apiKey.existingSecret` |

An existing Consul ACL token Secret needs **both** of these keys:

```bash
TOKEN=$(uuidgen)
cat > acl-tokens.json <<EOF
{"acl":{"tokens":{"initial_management":"${TOKEN}","agent":"${TOKEN}","default":"${TOKEN}"}}}
EOF
kubectl create secret generic my-consul-acl-token \
  --from-literal=token="${TOKEN}" \
  --from-file=acl-tokens.json=acl-tokens.json
```

## DERP

Headscale refuses to start with an empty DERP map, and this chart
refuses to silently default to Tailscale's public relay map for a
self-hosted deployment - `headscale.derp.urls` starts empty, and the
chart fails fast at template time unless you explicitly set one of:

- `headscale.derp.urls` - point at Tailscale's public map or any other
  third-party DERP map URL.
- `headscale.derp.customMap.enabled: true` - your own DERP map, either
  structured (`regions`, a map keyed by region ID) or raw text
  (`rawContent`, which takes precedence when set). Rendered into its own
  ConfigMap; headscale doesn't hot-reload local DERP map files, so a
  change here goes through an honest StatefulSet rolling restart
  (`checksum/derp-map` annotation), not a live reload.

```yaml
headscale:
  derp:
    customMap:
      enabled: true
      regions:
        900:
          RegionID: 900
          RegionCode: "custom"
          RegionName: "My custom DERP"
          Nodes:
            - Name: "900a"
              RegionID: 900
              HostName: "derp.example.com"
      # omitDefaultRegions: true   # drop Tailscale's defaults entirely
```

Running your **own embedded DERP server** (`headscale.derp.server.enabled`)
is deferred for now - it needs a whole separate story around exposing
STUN (UDP; Ingress is HTTP/L7-only and can't proxy it at all, and
leader-aware UDP routing needs more than this chart's Envoy setup
currently does). The plan is a dedicated chart for a real DERP cluster
later.

## ACL / policy

Three modes, `acl.enabled` + `acl.sync.enabled`:

1. **Disabled** (`acl.enabled: false`, default) - allow-all.
2. **Static** (`acl.enabled: true`, `acl.sync.enabled: false`) - policy
   defined structurally in `acl.policy` (`groups`, `tagOwners`, `hosts`,
   `acls`, `ssh`, `autoApprovers`) or as raw text (`acl.rawPolicy`, takes
   precedence when set), rendered into a ConfigMap and mounted as a file
   (`policy.mode: file`). A lightweight sidecar
   (`acl.reloadSidecar`, busybox, `shareProcessNamespace`) watches that
   file and sends headscale `SIGHUP` on change - the official way for
   headscale to reload policy without a restart.
3. **Synced from an identity provider** (`acl.sync.enabled: true`) - a
   separate `Deployment` running
   [headscale-pf](https://github.com/YouSysAdmin/headscale-pf), which on
   a schedule (`acl.sync.intervalSeconds`) pulls groups/users from
   Authentik/Jumpcloud/LDAP/Keycloak (`acl.sync.source.*`) and resolves
   them against the **same `acl.policy`/`acl.rawPolicy` as mode 2 above**
   - no separate template field. headscale-pf treats it as a template in
   this mode: it may overwrite whatever you put in `acl.policy.groups`
   with real membership from your source (`tagOwners`/`acls`/`ssh`/
   `autoApprovers` pass through as written). The result is applied via a
   `curl` `PUT` to headscale's REST API (`/api/v1/policy`, Bearer-token
   auth) - a live reload, no restart, no SIGHUP. Deliberately **not**
   gRPC: headscale's gRPC remote access hard-requires TLS
   ("Currently for a remote CLI you have no choice but to setup TLS" -
   [juanfont/headscale#1709](https://github.com/juanfont/headscale/issues/1709)),
   which this cluster's plaintext-internal Envoy mesh doesn't provide, and
   the REST API has no such requirement. `policy.mode: database` in this
   mode - headscale never reads a local policy file at all.

   The daemon needs a headscale API key, which can't be pre-generated
   offline (`headscale apikeys create` talks to a running `headscale
   serve` over its local unix socket, not the database directly, and only
   works on whichever pod is currently leader). No external Job, no
   `kubectl exec`, no pod-exec RBAC: whichever pod's `consul-agent`
   sidecar currently holds the lock notices Consul KV is missing the key
   and asks the `headscale` container next door - the only container with
   actual access to the headscale binary - to run the CLI command locally,
   handing the result back over a file on their shared volume. The result
   lands in Consul KV (`headscale/pf-api-key`), not a Kubernetes Secret
   (see [Secrets you need to create yourself](#secrets-you-need-to-create-yourself)
   for why), and self-heals - if the key is ever missing for any reason,
   the next pass re-requests it, no `helm upgrade` needed. Set
   `acl.sync.headscale.apiKey.existingSecret` instead if you'd rather
   manage the key yourself.

```yaml
acl:
  enabled: true
  policy:
    groups:
      group:admins:
        - "alice@example.com"
    acls:
      - action: accept
        src: ["group:admins"]
        dst: ["*:*"]
```

```yaml
acl:
  enabled: true
  policy:
    groups:
      group:admins: []   # headscale-pf fills this in from Authentik
    acls:
      - action: accept
        src: ["group:admins"]
        dst: ["*:*"]
  sync:
    enabled: true
    source:
      type: authentik
      endpoint: "https://auth.example.com"
      token: "CHANGE_ME"   # or source.existingSecret
```

## DNS

`dns.extraRecords` is rendered directly into `config.yaml`
(`dns.extra_records`). Headscale doesn't hot-reload DNS records, so a
change here goes through the same `checksum/config`-triggered rolling
restart as any other config change - no separate mechanism, no CronJob.

## Consul ACL (`ha.consul.acl`)

```yaml
ha:
  consul:
    acl:
      enabled: true
      token:
        value: "CHANGE_ME"   # a uuid you generate yourself; or token.existingSecret
```

- `acl.enabled = true`, `default_policy = "deny"` in the Consul server
  config - the cluster now rejects unauthenticated requests.
- **One shared token** everywhere: the servers' own
  `initial_management`/`agent`/`default` tokens, and every consul-agent
  sidecar's `CONSUL_HTTP_TOKEN`. This is a "basic" tier on purpose -
  simple to reason about, but not least-privilege. Any pod that can read
  the token Secret has full admin rights over Consul, not just
  headscale's own keys.
- You provide the token - see
  [Secrets you need to create yourself](#secrets-you-need-to-create-yourself)
  for the exact `existingSecret` shape (needs both a `token` key and an
  `acl-tokens.json` key).

## extraEnv / secretsEnv

Both are **maps**, not lists - specifically so CI tools that merge
several values files (Helmfile environments, etc.) can combine entries
from different files. Helm/Helmfile merge maps key-by-key, but a list
from one file completely replaces a list from another; there's no
merging, whichever file applies last wins outright.

```yaml
extraEnv:
  PLAIN_VAR: "some value"                  # -> value: ...
  FROM_SECRET:                             # -> valueFrom: ...
    secretKeyRef:
      name: some-secret
      key: some-key

secretsEnv:
  SOME_TOKEN: "plaintext-value"            # chart wraps this into a Secret,
                                            # wired in via envFrom
```

`extraEnv` supports any valid `EnvVarSource` under the hood
(`configMapKeyRef`, `fieldRef`, `resourceFieldRef`, ...) - passed through
as-is. `secretsEnv` is a narrower RBAC boundary than `extraEnv` (the
values end up in an actual Secret object, not visible via plain
`kubectl get pod -o yaml`) but **not** a GitOps-safe secrets story - the
value still sits in plaintext in whatever values file you're using. If
you need secrets to not exist in git at all, use `existingSecret`-style
options elsewhere in this chart plus your own external secret-management
tooling instead.

The same two options exist under `postgresql.extraEnv`/`postgresql.secretsEnv`
for the bundled Postgres container.

## extraManifests

Renders any additional Kubernetes objects alongside this chart's own - a
`NetworkPolicy`, a `PrometheusRule`, an `ExternalSecret` pulling the
secrets above from a vault, etc. Each entry is templated with `tpl`, so
chart values/helpers work inside:

```yaml
extraManifests:
  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: '{{ include "headscale.fullname" . }}-noise-key'
    spec:
      # ...
```

## Ingress

Routes HTTP (`service.httpPort`) only, on purpose. Tailscale client nodes
talk to headscale over that HTTP control-plane endpoint; gRPC
(`service.grpcPort`) is the admin/CLI API and generally isn't meant to be
publicly exposed (use `kubectl exec`/port-forward instead). A standard
Kubernetes Ingress also doesn't proxy gRPC correctly without explicit
controller-specific config (e.g. nginx's `backend-protocol: "GRPC"`
annotation, HTTP/2 end-to-end) - if you need remote gRPC access, that's a
separate Ingress/route with that config, not this one.

## Known limitations

- Failover isn't instant - bounded below by Consul's session TTL/lock-delay
  (~15s each, not currently configurable - see the comment on `ha.lock` in
  `values.yaml` for why) plus however long headscale takes to start and
  read the database, realistically low tens of seconds. Inherent to
  headscale only reading state at startup, not something Consul/Envoy can
  shortcut.
- Consul's HTTP health check has no built-in flap-damping - a single slow
  poll can trigger a failover. `ha.envoy.activeHealthCheck` is a second,
  independent gate before real traffic actually shifts, which softens
  (but doesn't eliminate) that risk.
- No gossip encryption or TLS between Consul agents by default -
  `ha.consul.acl.enabled` covers request authorization, not transport
  security. Fine for traffic confined to the cluster's internal network;
  add your own if that's not your threat model.
- The bundled PostgreSQL is a single instance with a single PVC - not
  highly available.
