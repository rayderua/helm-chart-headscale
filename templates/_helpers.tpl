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

{{/* gRPC address for headscale-pf -> headscale */}}
{{- define "headscale.grpcAddress" -}}
{{- if .Values.acl.sync.headscale.grpcAddress -}}
{{- .Values.acl.sync.headscale.grpcAddress -}}
{{- else -}}
{{- printf "%s-headless.%s.svc:%v" (include "headscale.fullname" .) .Release.Namespace .Values.service.grpcPort -}}
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

{{/* Consul KV path where the headscale-pf API key is auto-provisioned */}}
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
