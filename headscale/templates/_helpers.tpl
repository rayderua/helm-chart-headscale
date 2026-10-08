{{/*
Chart name
*/}}
{{- define "headscale.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fullname
*/}}
{{- define "headscale.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "headscale.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "headscale.labels" -}}
helm.sh/chart: {{ include "headscale.chart" . }}
{{ include "headscale.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "headscale.selectorLabels" -}}
app.kubernetes.io/name: {{ include "headscale.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "headscale.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "headscale.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Image reference with fallback to appVersion */}}
{{/* Image reference with fallback to appVersion. Fails fast if neither the
repository nor the tag mentions "alpine": the headscale container's command
is a shell script (needed for the leader/standby start-stop supervisor),
and the default (non-alpine) headscale/headscale image ships no shell at
all - it fails to exec silently, with nothing at all in `kubectl logs` (the
container never gets far enough to log anything), which is a genuinely
nasty thing to debug blind. Catching it here instead - checks both
repository and tag since a custom image (e.g. "myorg/headscale-alpine")
might carry "alpine" in its name rather than its tag. */}}
{{- define "headscale.image" -}}
{{- $tag := .Values.image.tag | default (printf "%s-alpine" .Chart.AppVersion) -}}
{{- if not (or (contains "alpine" .Values.image.repository) (contains "alpine" $tag)) -}}
{{ fail (printf "neither image.repository (%q) nor image.tag (%q) mentions \"alpine\". The default headscale/headscale image has no shell, which the HA start/stop supervisor script needs - use an alpine-based image/tag, or a custom image with a shell baked in." .Values.image.repository $tag) }}
{{- end -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{/* Name of the Secret holding the postgres password */}}
{{- define "headscale.postgresSecretName" -}}
{{- if .Values.database.postgres.existingSecret -}}
{{- .Values.database.postgres.existingSecret -}}
{{- else -}}
{{- printf "%s-postgres" (include "headscale.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "headscale.postgresSecretKey" -}}
{{- if .Values.database.postgres.existingSecret -}}
{{- .Values.database.postgres.existingSecretPasswordKey -}}
{{- else -}}
password
{{- end -}}
{{- end -}}

{{/* Postgres host: bundled StatefulSet Service when postgresql.enabled, otherwise the value from database.postgres.host */}}
{{- define "headscale.postgresHost" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s-postgresql.%s.svc" (include "headscale.fullname" .) .Release.Namespace -}}
{{- else -}}
{{- .Values.database.postgres.host -}}
{{- end -}}
{{- end -}}

{{/* Postgres port: bundled service port when postgresql.enabled, otherwise database.postgres.port */}}
{{- define "headscale.postgresPort" -}}
{{- if .Values.postgresql.enabled -}}
{{- .Values.postgresql.service.port -}}
{{- else -}}
{{- .Values.database.postgres.port -}}
{{- end -}}
{{- end -}}

{{/* Name of the Secret holding the noise private key */}}
{{- define "headscale.noiseSecretName" -}}
{{- if .Values.noisePrivateKey.existingSecret -}}
{{- .Values.noisePrivateKey.existingSecret -}}
{{- else -}}
{{- printf "%s-noise-key" (include "headscale.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "headscale.noiseSecretKey" -}}
{{- if .Values.noisePrivateKey.existingSecret -}}
{{- .Values.noisePrivateKey.existingSecretKey -}}
{{- else -}}
noise_private.key
{{- end -}}
{{- end -}}

{{/* aclSync source token secret */}}
{{- define "headscale.aclSyncSourceSecretName" -}}
{{- if .Values.acl.sync.source.existingSecret -}}
{{- .Values.acl.sync.source.existingSecret -}}
{{- else -}}
{{- printf "%s-acl-sync-source" (include "headscale.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "headscale.aclSyncSourceSecretKey" -}}
{{- if .Values.acl.sync.source.existingSecret -}}
{{- .Values.acl.sync.source.existingSecretKey -}}
{{- else -}}
token
{{- end -}}
{{- end -}}

{{/* aclSync headscale API key secret */}}
{{- define "headscale.aclSyncApiKeySecretName" -}}
{{- if .Values.acl.sync.headscale.apiKey.existingSecret -}}
{{- .Values.acl.sync.headscale.apiKey.existingSecret -}}
{{- else -}}
{{- printf "%s-acl-sync-apikey" (include "headscale.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "headscale.aclSyncApiKeySecretKey" -}}
{{- if .Values.acl.sync.headscale.apiKey.existingSecret -}}
{{- .Values.acl.sync.headscale.apiKey.existingSecretKey -}}
{{- else -}}
api-key
{{- end -}}
{{- end -}}

{{/* HTTP API base URL for headscale-pf -> headscale (REST, not gRPC - see
values.yaml acl.sync.headscale for why: headscale's gRPC remote access
requires TLS, its REST API doesn't). Goes through the regular Service (not
headless) - Envoy answers identically on every pod regardless, so there's
no need for per-pod headless resolution here. */}}
{{- define "headscale.httpApiAddress" -}}
{{- if .Values.acl.sync.headscale.apiUrl -}}
{{- .Values.acl.sync.headscale.apiUrl -}}
{{- else -}}
{{- printf "http://%s.%s.svc:%v" (include "headscale.fullname" .) .Release.Namespace .Values.service.httpPort -}}
{{- end -}}
{{- end -}}

{{/* ============================= HA / Consul ============================= */}}

{{- define "headscale.consulFullname" -}}
{{- printf "%s-consul" (include "headscale.fullname" .) -}}
{{- end -}}

{{/* DNS name consul agents use to find the server cluster (retry_join) */}}
{{- define "headscale.consulJoinAddress" -}}
{{- printf "%s-headless.%s.svc" (include "headscale.consulFullname" .) .Release.Namespace -}}
{{- end -}}

{{/* Local agent HTTP API, reachable over loopback from sidecars in the same pod */}}
{{- define "headscale.consulLocalHttpAddr" -}}
127.0.0.1:8500
{{- end -}}

{{/* Consul HTTP API reachable from pods WITHOUT a local agent sidecar (e.g. the acl-sync Deployment) */}}
{{- define "headscale.consulServiceHttpAddr" -}}
{{- printf "%s.%s.svc:8500" (include "headscale.consulFullname" .) .Release.Namespace -}}
{{- end -}}

{{/* Guard rail: Consul server replica count must support Raft quorum */}}
{{- define "headscale.haValidate" -}}
{{- if eq (mod (.Values.ha.consul.replicas | int) 2) 0 -}}
{{ fail "ha.consul.replicas must be an odd number (Raft quorum), e.g. 3 or 5" }}
{{- end -}}
{{- if lt (.Values.ha.consul.replicas | int) 3 -}}
{{ fail "ha.consul.replicas must be at least 3 for a Consul server cluster to tolerate any failure" }}
{{- end -}}
{{- end -}}

{{/* Name of the Secret holding the shared Consul ACL token */}}
{{- define "headscale.consulAclSecretName" -}}
{{- if .Values.ha.consul.acl.token.existingSecret -}}
{{- .Values.ha.consul.acl.token.existingSecret -}}
{{- else -}}
{{- printf "%s-acl-token" (include "headscale.consulFullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Renders a map of extraEnv entries (not a list, so CI tools like
helmfile that merge multiple values files can combine entries instead of
one file's list silently replacing another's) into standard k8s env
entries. Each value is either a plain scalar (-> `value: ...`) or a map
(-> `valueFrom: ...`, passed through as-is so secretKeyRef/configMapKeyRef/
fieldRef/etc all just work). */}}
{{- define "headscale.renderExtraEnv" -}}
{{- range $key, $val := . }}
- name: {{ $key }}
{{- if kindIs "map" $val }}
  valueFrom:
{{ toYaml $val | indent 4 }}
{{- else }}
  value: {{ $val | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Guard: refuse to start with no DERP source at all - and refuse to
silently default to Tailscale's public relays, since this chart is for
running your own headscale. HTTPS-only for now (urls or customMap) -
embedded DERP server (headscale.derp.server.enabled) isn't a supported
path here yet, it needs a whole separate story around exposing STUN
(UDP), planned as its own chart later. */}}
{{- define "headscale.derpValidate" -}}
{{- $hasUrls := gt (len .Values.headscale.derp.urls) 0 -}}
{{- $hasCustomMap := .Values.headscale.derp.customMap.enabled -}}
{{- if not (or $hasUrls $hasCustomMap) -}}
{{ fail "headscale.derp: no DERP source configured, and this chart won't silently default to Tailscale's public relays for a self-hosted deployment. Set ONE of: headscale.derp.urls (use a public/third-party DERP map) or headscale.derp.customMap.enabled: true (bring your own DERP map)." }}
{{- end -}}
{{- end -}}

{{/* Single source of truth for ACL policy JSON, used by BOTH the static
(policy.mode: file) and sync (headscale-pf --input-policy) paths -
acl.rawPolicy takes precedence when set, otherwise built field-by-field
from the structured acl.policy so each value gets its own toJson call
(cleaner errors on a bad type than json-ing the whole map at once). Note
for sync mode specifically: `groups` here is a seed/template for
headscale-pf, not guaranteed final content - headscale-pf resolves group
membership from your external source and may overwrite whatever you put
here. Everything else passes through as written. */}}
{{- define "headscale.renderAclPolicy" -}}
{{- if .Values.acl.rawPolicy -}}
{{ .Values.acl.rawPolicy }}
{{- else -}}
{{- $policy := .Values.acl.policy | deepCopy -}}

{{/* Merge acl.extraHosts[*].address as simple host aliases, same as
manually writing them into acl.policy.hosts. */}}
{{- $hosts := index $policy "hosts" | default dict -}}
{{- range $hostName, $hostData := .Values.extraHosts -}}
{{- $_ := set $hosts $hostName $hostData.address -}}
{{- end -}}
{{- $_ := set $policy "hosts" $hosts -}}

{{/* headscale has no native "host group"/ipset construct - build a
tag -> [hostnames] reverse map from extraHosts[*].tags so extraAcl rules
(below) can use "tag:<name>" to mean "every host carrying this tag". */}}
{{- $tagMap := dict -}}
{{- range $hostName, $hostData := .Values.extraHosts -}}
{{- range $tag := ($hostData.tags | default list) -}}
{{- $list := index $tagMap $tag | default list -}}
{{- $_ := set $tagMap $tag (append $list $hostName) -}}
{{- end -}}
{{- end -}}

{{/* .Values.extraAcl holds rules shaped exactly like acl.policy.acls,
except "dst" entries can use "tag:<name>" or "tag:<name>:<port>" as a
pseudo-tag referencing extraHosts groups. These NEVER reach the final
policy in that raw form - headscale validates every "tag:" reference
against tagOwners and rejects the WHOLE policy if one doesn't resolve, so
a pseudo-tag with no real tagOwners entry would break everything if left
in place (this used to happen: the same rule was kept both raw and
expanded - fixed by only ever emitting the expanded form). Non-tag dst
entries in an extraAcl rule pass through unchanged; an unknown pseudo-tag
fails the whole template render rather than silently dropping the rule -
a silently-missing ACL rule is a worse failure mode than a loud one. */}}
{{- $expandedExtraAcls := list -}}
{{- range $acl := (.Values.extraAcl | default list) -}}
{{- $expandedDst := list -}}
{{- range $dst := (index $acl "dst" | default list) -}}
{{- if hasPrefix "tag:" $dst -}}
{{- $parts := splitList ":" $dst -}}
{{- $tagName := index $parts 1 -}}
{{- $port := "*" -}}
{{- if ge (len $parts) 3 -}}
{{- $port = index $parts 2 -}}
{{- end -}}
{{- if not (hasKey $tagMap $tagName) -}}
{{ fail (printf "extraAcl references tag:%s, which no extraHosts entry carries in its tags list - fix the typo, or add it to an extraHosts entry's tags" $tagName) }}
{{- end -}}
{{- range $hostName := index $tagMap $tagName -}}
{{- $expandedDst = append $expandedDst (printf "%s:%s" $hostName $port) -}}
{{- end -}}
{{- else -}}
{{- $expandedDst = append $expandedDst $dst -}}
{{- end -}}
{{- end -}}
{{- $newAcl := $acl | deepCopy -}}
{{- $_ := set $newAcl "dst" $expandedDst -}}
{{- $expandedExtraAcls = append $expandedExtraAcls $newAcl -}}
{{- end -}}
{{- $_ := set $policy "acls" (concat ($policy.acls | default list) $expandedExtraAcls) -}}

{{ $policy | toPrettyJson }}
{{- end -}}
{{- end -}}

{{/* Combines dns.extraRecords (manual) with records auto-generated from
extraHosts (skips any entry with dns: false - defaults to true when the
key is absent). Strips a CIDR suffix (/32, /24, ...) from the address if
present - only really meaningful for single-host entries (/32, /128, or a
bare IP); a broader subnet will produce a record pointing at the network
address, which is why per-host dns:false exists for exactly that case.
Picks A vs AAAA by whether the address contains a colon. Returns a
compact JSON array (not YAML) so it can be embedded as-is into the
dns-records ConfigMap file (see configmap-dns-records.yaml) as well as
parsed back with fromJsonArray for the inline config.yaml case. */}}
{{- define "headscale.dnsExtraRecordsJson" -}}
{{- $records := list -}}
{{- range .Values.dns.extraRecords -}}
{{- $records = append $records . -}}
{{- end -}}
{{- range $name, $data := .Values.extraHosts -}}
{{- /* Default depends on whether the address is a single host (/32,
/128, or a bare IP with no CIDR at all) vs a broader subnet - a subnet
address isn't a meaningful DNS target, so it defaults to no record
unless you explicitly say dns: true (explicit always wins either way). */ -}}
{{- $isSingleHost := true -}}
{{- if contains "/" $data.address -}}
{{- $prefixLen := last (splitList "/" $data.address) -}}
{{- if not (or (eq $prefixLen "32") (eq $prefixLen "128")) -}}
{{- $isSingleHost = false -}}
{{- end -}}
{{- end -}}
{{- $wantsDns := $isSingleHost -}}
{{- if hasKey $data "dns" -}}
{{- $wantsDns = $data.dns -}}
{{- end -}}
{{- if $wantsDns -}}
{{- $ip := $data.address -}}
{{- if contains "/" $ip -}}
{{- $ip = first (splitList "/" $ip) -}}
{{- end -}}
{{- $type := "A" -}}
{{- if contains ":" $ip -}}
{{- $type = "AAAA" -}}
{{- end -}}
{{- $records = append $records (dict "name" $name "type" $type "value" $ip) -}}
{{- end -}}
{{- end -}}
{{- $records | toJson -}}
{{- end -}}

{{- define "headscale.aclSyncApiKeyKvPath" -}}
headscale/pf-api-key
{{- end -}}

{{/* Consul KV path publishing the CURRENT leader's pod name (not just its
IP) - needed because `headscale apikeys create` connects to the local
unix socket of an already-running `headscale serve`, so callers need to
know which specific pod to `kubectl exec` into, not just its address. */}}
{{- define "headscale.leaderPodKvPath" -}}
headscale/leader-pod
{{- end -}}
