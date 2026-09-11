# headscale Helm chart

Helm chart for deploying [Headscale](https://github.com/juanfont/headscale)
(a self-hosted Tailscale control server) as an always-HA, 3-pod
`StatefulSet` in Kubernetes, with Consul-driven leader election and an
Envoy sidecar mesh for traffic routing.

## Features

- **Always HA, always PostgreSQL**: this chart only runs headscale as a
  3-pod StatefulSet with Consul-driven leader election - there's no
  single-instance mode, and no sqlite support (a local-file database can't
  be shared across pods, which HA fundamentally requires). See "High
  availability" below for how leader election, failover, and traffic
  routing actually work.
- The postgres password is never written to a ConfigMap - it's passed via
  the `HEADSCALE_DATABASE_POSTGRES_PASSWORD` environment variable, sourced
  from a Secret (your own or an `existingSecret`).
- **Bundled PostgreSQL** (optional): `postgresql.enabled=true` deploys a
  single-instance PostgreSQL `StatefulSet` on its own PVC, right next to
  headscale, reusing the same credentials/Secret. Not highly available -
  intended for small/medium deployments that don't want to depend on an
  external database. See the "PostgreSQL" section below.
- Uses the **official image** `headscale/headscale`.
- **noise_private.key**: provide it yourself, either
  `noisePrivateKey.value` (the chart wraps it in a Secret) or
  `noisePrivateKey.existingSecret` (a Secret you already manage). This
  chart doesn't generate or rotate it for you - see "Generating a
  noise_private.key" below if you need one.
- **extraDnsRecords**: `dns.extraRecords` is rendered directly into
  `config.yaml` (`dns.extra_records`). Headscale doesn't hot-reload DNS
  records, so a change here goes through the normal `checksum/config`
  rolling restart like any other config change.
- **ACL generation**: `acl.enabled` + structured `acl.policy`
  (groups/tagOwners/hosts/acls/ssh) is rendered into `policy.hujson` (or
  `acl.rawPolicy` for raw text). Changes are hot-reloaded, see below.
- **No unnecessary headscale restarts**. Headscale can only truly hot-reload
  two things at runtime, and this chart relies on exactly those:
  - **Policy (ACL)** - via `headscale policy set` (gRPC) or SIGHUP. No pod
    restart is required in either mode described below.
  - **DNS extra records** - via `dns.extra_records_path`: headscale
    continuously watches the file and picks up changes, also without a
    restart or any signal.

  All other `config.yaml` settings (database type, listen_addr, etc.) can
  only be applied by headscale at process start - for those, the standard
  `checksum/config` annotation is used to trigger a StatefulSet rolling
  restart, but **only** when those specific settings change, not ACL/DNS.

### ACL: two modes

1. **Static** (`acl.enabled=true`, `acl.sync.enabled=false`) - policy is
   defined structurally in `acl.policy` (or `acl.rawPolicy`), rendered into
   a ConfigMap -> `policy.hujson`, and headscale reads the file
   (`policy.mode: file`). A lightweight sidecar container
   (`acl.reloadSidecar`, busybox) is added to the pod, using
   `shareProcessNamespace` to watch the file and send headscale a `SIGHUP`
   on change - the official way for headscale to reload policy without a
   restart.

2. **Sync from Authentik/Jumpcloud/LDAP/Keycloak**
   (`acl.sync.enabled=true`) - a separate `Deployment` running the
   [headscale-pf](https://github.com/YouSysAdmin/headscale-pf) daemon, which
   on a schedule (`acl.sync.intervalSeconds`):
   - pulls groups/users from the source (`acl.sync.source.type`:
     `authentik`/`jumpcloud`/`ldap`/`keycloak`);
   - fills them into a policy template (`acl.sync.policyTemplate`, HJSON);
   - applies the result via `headscale policy set` over gRPC - a **live
     reload, no restart, no SIGHUP**.

   In this mode `policy.mode: database` - headscale never reads a local
   policy file at all, and the ACL ConfigMap / reload sidecar are not
   created.

   The daemon needs a headscale API key for gRPC access. This can't be
   pre-generated offline like the noise key or Consul ACL token:
   `headscale apikeys create` connects to a running `headscale serve`
   process over its local unix socket, not the database directly - so it
   only works via `kubectl exec` into whichever pod is *currently the
   leader* (the other two don't have headscale running at all). A
   post-install/post-upgrade `Job` asks Consul KV who that is right now
   (`headscale/leader-pod`, published by the same lock-holding sidecar that
   publishes the leader's IP for envoy), execs into that pod, and stores
   the resulting key in **Consul KV** (`headscale/pf-api-key`) - not a
   Kubernetes Secret, since a Secret written imperatively by a Job is
   invisible to GitOps tools like Argo CD (it never appears in the
   rendered manifest set, so it's either untracked or fought over on every
   sync/prune). Consul KV has no such problem since Argo CD has no opinion
   about it at all.
   
   Set `acl.sync.headscale.apiKey.existingSecret` instead if you'd rather
   manage the key yourself; the chart then skips the Job and the Consul-KV
   fetch entirely and reads from that Secret.

### DNS

`dns.extraRecords` is rendered directly into `config.yaml`
(`dns.extra_records`). Headscale doesn't hot-reload DNS records, so a
change here goes through the same `checksum/config`-triggered rolling
restart as any other config change - no separate mechanism, no CronJob.

## Secrets you need to create yourself

This chart deliberately does not generate any random secrets on your
behalf (GitOps tools like Argo CD can't track resources created
out-of-band by a Job, so it's not a good fit here - see the `acl.sync` API
key note above for the one case that's unavoidably deploy-time). Anything
that *can* be generated offline, generate it yourself and feed it in:

| Secret | Generate with | Wire it in via |
|---|---|---|
| `noise_private.key` | e.g. `head -c32 /dev/urandom \| xxd -p -c32` | `noisePrivateKey.value` or `.existingSecret` |
| Consul ACL token | e.g. `uuidgen` | `ha.consul.acl.token.value` or `.existingSecret` |
| Postgres password | your usual secret tooling | `database.postgres.password` or `.existingSecret` |
| headscale-pf source token (Authentik etc.) | issued by that system | `acl.sync.source.token` or `.existingSecret` |
| headscale-pf API key | **can't** be pre-generated - see above | provisioned into Consul KV automatically, or `acl.sync.headscale.apiKey.existingSecret` |

For an existing Consul ACL token Secret specifically, it needs both keys:

```bash
TOKEN=$(uuidgen)
cat > acl-tokens.json <<EOF
{"acl":{"tokens":{"initial_management":"${TOKEN}","agent":"${TOKEN}","default":"${TOKEN}"}}}
EOF
kubectl create secret generic my-consul-acl-token \
  --from-literal=token="${TOKEN}" \
  --from-file=acl-tokens.json=acl-tokens.json
```

## extraManifests

`extraManifests` renders any additional Kubernetes objects alongside this
chart's own - a `NetworkPolicy`, a `PrometheusRule`, an `ExternalSecret`
that pulls the secrets above from a vault, etc. Each entry is templated
with `tpl`, so chart values/helpers work inside:

```yaml
extraManifests:
  - apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: '{{ include "headscale.fullname" . }}-noise-key'
    spec:
      # ...
```

## Quick start

Needs, at minimum, an `-alpine` image tag (for the in-pod supervisor
script's shell) and a noise key you've generated yourself:

```bash
openssl rand -hex 32 > /tmp/noise.key   # or however you prefer to generate one

helm install headscale ./headscale \
  --set headscale.serverUrl=https://headscale.example.com \
  --set image.tag=latest-alpine \
  --set-file noisePrivateKey.value=/tmp/noise.key \
  --set postgresql.enabled=true \
  --set database.postgres.password=CHANGE_ME
```

This uses the bundled single-instance PostgreSQL (see below) to keep the
example short - point `database.postgres.host` at an external instance
instead for anything beyond quick testing.

### Bundled PostgreSQL

```bash
helm install headscale ./headscale \
  --set postgresql.enabled=true \
  --set database.postgres.user=headscale \
  --set database.postgres.name=headscale \
  --set database.postgres.password=CHANGE_ME \
  --set postgresql.persistence.size=5Gi
```

This deploys a single-instance PostgreSQL `StatefulSet`
(`<release>-postgresql`) with its own PVC, and headscale automatically
connects to it - `database.postgres.host`/`port` are filled in internally,
you don't need to set them. The password you provide is stored in one
Secret, shared by both headscale and the bundled PostgreSQL container.

If you'd rather use an external/managed Postgres instance, leave
`postgresql.enabled=false` and set `database.postgres.host` (and
`existingSecret`, if applicable) yourself.

### ACL (static, hot-reloaded via SIGHUP)

```yaml
acl:
  enabled: true
  policy:
    groups:
      group:admins:
        - "alice@example.com"
    tagOwners:
      tag:server:
        - "group:admins"
    acls:
      - action: accept
        src: ["group:admins"]
        dst: ["*:*"]
```

### ACL sync from Authentik (headscale-pf, live reload without a restart)

```yaml
acl:
  enabled: true
  sync:
    enabled: true
    intervalSeconds: 300
    source:
      type: authentik
      endpoint: "https://auth.example.com"
      token: "CHANGE_ME"   # or existingSecret
    policyTemplate: |
      {
        "groups": { "group:admins": [] },
        "tagOwners": {},
        "acls": [
          {"action": "accept", "src": ["group:admins"], "dst": ["*:*"]}
        ]
      }
```

## High availability

Headscale always runs as an active/standby, 3-pod StatefulSet with
automatic, self-fenced failover - there's no single-instance mode, and
turning HA off isn't an option. No external Helm chart dependency, no
separate load balancer in front of the StatefulSet - everything needed
lives in this chart:

- **A lightweight, self-hosted Consul server cluster** (`ha.consul.*`) -
  the official `hashicorp/consul` container image, deployed directly as a
  `StatefulSet` by this chart (not the `hashicorp/consul` Helm chart, no
  chart dependency). Server-only, no ACLs by default, no gossip
  encryption, no TLS - fine for traffic confined to the cluster's internal
  network; `ha.consul.acl.enabled` adds basic ACL auth (see below), and
  gossip encryption/TLS are separate hardening steps this chart still
  doesn't set up for you.
- **A `consul-agent` sidecar** in every headscale pod, which: races the
  other pods for a Consul KV lock (`headscale/leader`) to decide who's
  active; polls the local headscale process's own `/health` over loopback
  and releases the lock the moment it stops responding (self-fencing);
  publishes the current leader's pod IP and pod name to Consul KV.
- **An `envoy` sidecar** in every headscale pod, listening on the exact
  ports the Service already exposes (`service.httpPort`/`grpcPort`) and
  forwarding every connection to whichever pod is currently the leader -
  locally, or over the pod network to a sibling. The k8s Service and any
  Ingress in front of it never change; the routing intelligence lives
  entirely inside the pods.
- **The headscale container itself runs a tiny supervisor script** instead
  of a bare `headscale serve`: it starts the real process only once its
  sidecar has marked the pod as leader, and stops it the instant that
  stops being true. Since headscale only reads DB state at process start,
  becoming leader always means a fresh process start here, never resuming
  a paused one.

### Requirements

- `image.tag` must be an `-alpine` variant of `headscale/headscale` (e.g.
  `latest-alpine`) - the default image ships no shell at all, and the
  supervisor script needs one.
- `ha.consul.replicas` must stay odd (Raft quorum) - the chart fails fast
  with a clear error otherwise.
- `noisePrivateKey.value`/`existingSecret` must be set (see "Secrets you
  need to create yourself" above) - all 3 pods share the same one.

### What this doesn't cover (yet)

- No Consul ACLs or gossip encryption by default - anyone inside the
  namespace can, in principle, read/write the leader lock. Set
  `ha.consul.acl.enabled: true` for basic auth (see below); gossip
  encryption/TLS are separate, unrelated hardening steps this chart
  doesn't set up.
- Failover isn't instant - it's bounded below by
  `ha.lock.sessionTTL` + `ha.lock.lockDelay` + however long headscale takes
  to start and read the database, realistically low tens of seconds. This
  is inherent to headscale only reading state at startup, not something
  Consul/Envoy can shortcut.
- Consul's HTTP health check has no built-in flap-damping - a single slow
  poll can trigger a failover. `ha.envoy.activeHealthCheck` is a second,
  independent gate before real traffic actually shifts, which softens
  (but doesn't eliminate) that risk.

### Basic Consul ACL (`ha.consul.acl.enabled`)

```yaml
ha:
  consul:
    acl:
      enabled: true
      token:
        value: "CHANGE_ME"   # or token.existingSecret - you generate this
                              # yourself (e.g. `uuidgen`), same as noisePrivateKey
```

What this actually does:
- `acl.enabled = true`, `default_policy = "deny"` in the Consul server
  config - the cluster now rejects unauthenticated requests.
- **One shared token** is used everywhere: the servers' own
  `initial_management`/`agent`/`default` tokens, and every consul-agent
  sidecar's `CONSUL_HTTP_TOKEN`. This is the "basic" tier on purpose -
  simple to reason about, but not least-privilege. Any pod that can read
  the token Secret has full admin rights over Consul, not just headscale's
  own keys. Splitting into scoped per-purpose policies/tokens is a natural
  next step this toggle doesn't do for you.
- You provide the token - the chart doesn't generate it. Either
  `ha.consul.acl.token.value` (the chart wraps it in a Secret) or
  `ha.consul.acl.token.existingSecret` (a Secret you already manage, which
  must contain both a `token` key with the raw value, and an
  `acl-tokens.json` key with `{"acl":{"tokens":{"initial_management":"...","agent":"...","default":"..."}}}`
  using that same value).

## Notes

- Headscale always runs as 3 pods with Consul-driven leader election -
  there's no single-instance mode and no arbitrary replica count.
- The bundled PostgreSQL `StatefulSet` is a single instance with a single
  PVC - not highly available. It's a convenience option, not a replacement
  for a managed database in production.
- `helperImage` (default `alpine/k8s`) is only used by the
  `acl.sync` API-key-provisioning Job - it must contain `bash`, `kubectl`,
  `curl`.
