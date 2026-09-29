{{/* Chart name. */}}
{{- define "rmqtt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name (also the StatefulSet name, so pods are <fullname>-<ordinal>). */}}
{{- define "rmqtt.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 52 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 52 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 52 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "rmqtt.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rmqtt.labels" -}}
helm.sh/chart: {{ include "rmqtt.chart" . }}
{{ include "rmqtt.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "rmqtt.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rmqtt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "rmqtt.headlessServiceName" -}}
{{- printf "%s-headless" (include "rmqtt.fullname" .) }}
{{- end }}

{{- define "rmqtt.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "rmqtt.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "rmqtt.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Stable per-pod DNS name of node <ordinal>. */}}
{{- define "rmqtt.podHost" -}}
{{- $ := index . 0 }}{{- $i := index . 1 -}}
{{- printf "%s-%d.%s.%s.svc.cluster.local" (include "rmqtt.fullname" $) $i (include "rmqtt.headlessServiceName" $) $.Release.Namespace }}
{{- end }}

{{/*
Repeated, shell-quoted "--<flag> '<id>@<host>:<port>'" arguments for all nodes. Arg: (list $ flag port).
clap parses Option<Vec<NodeAddr>> one value per occurrence, so the flag must be repeated.
*/}}
{{- define "rmqtt.peerArgs" -}}
{{- $ := index . 0 }}{{- $flag := index . 1 }}{{- $port := index . 2 -}}
{{- $args := list }}
{{- range $i := until (int $.Values.replicaCount) }}
{{- $args = append $args (printf "--%s '%d@%s:%d'" $flag (add1 $i) (include "rmqtt.podHost" (list $ $i)) (int $port)) }}
{{- end }}
{{- join " " $args }}
{{- end }}

{{/* Name of the Secret holding ACL passwords (one key per user). */}}
{{- define "rmqtt.aclSecretName" -}}
{{- default (printf "%s-acl-passwords" (include "rmqtt.fullname" .)) .Values.acl.existingSecret }}
{{- end }}

{{- define "rmqtt.apiTokenSecretName" -}}
{{- default (printf "%s-http-api-token" (include "rmqtt.fullname" .)) .Values.httpApi.bearerToken.existingSecret }}
{{- end }}

{{- define "rmqtt.apiTokenSecretKey" -}}
{{- if .Values.httpApi.bearerToken.existingSecret }}{{ .Values.httpApi.bearerToken.existingSecretKey }}{{ else }}token{{ end }}
{{- end }}

{{- define "rmqtt.passwordKey" -}}
{{- $key := default .username .passwordKey -}}
{{- if not (regexMatch "^[-._a-zA-Z0-9]+$" $key) -}}
{{- fail (printf "acl.users: passwordKey %q (user %q) must match [-._a-zA-Z0-9]+; set passwordKey explicitly" $key .username) -}}
{{- end -}}
{{- $key -}}
{{- end }}

{{/* TOML basic string. JSON string escapes are a subset of TOML's. */}}
{{- define "rmqtt.tomlString" -}}
{{- toJson (toString .) -}}
{{- end }}

{{- define "rmqtt.tomlTopic" -}}
{{- if kindIs "map" . -}}
{{- if not (hasKey . "eq") }}{{ fail (printf "acl topic map must be { eq: \"...\" }, got %v" .) }}{{ end -}}
{ eq = {{ include "rmqtt.tomlString" .eq }} }
{{- else -}}
{{- include "rmqtt.tomlString" . -}}
{{- end -}}
{{- end }}

{{/*
Validate values. Called from the StatefulSet so every render fails fast.
*/}}
{{- define "rmqtt.validate" -}}
{{- if lt (int .Values.replicaCount) 1 }}{{ fail "replicaCount must be >= 1" }}{{ end }}
{{- $lid := int .Values.cluster.leaderId }}
{{- if or (lt $lid 1) (gt $lid (int .Values.replicaCount)) }}
{{- fail "cluster.leaderId must be between 1 and replicaCount (0 re-enables the split-brain prone auto mode)" }}
{{- end }}
{{- if not (has .Values.acl.finalRule (list "deny" "allow")) }}{{ fail "acl.finalRule must be \"deny\" or \"allow\"" }}{{ end }}
{{- range .Values.acl.extraRules }}
{{- if contains "password" (lower .) }}{{ fail "acl.extraRules must not contain passwords; declare the user in acl.users and put the password in the password Secret" }}{{ end }}
{{- end }}
{{- $seen := dict }}
{{- range .Values.acl.users }}
{{- if not .username }}{{ fail "acl.users[].username is required" }}{{ end }}
{{- if hasKey . "password" }}{{ fail (printf "acl.users[%s].password is not allowed; put it in values-secrets.yaml (aclPasswords) or acl.existingSecret" .username) }}{{ end }}
{{- $key := include "rmqtt.passwordKey" . }}
{{- if hasKey $seen .username }}{{ fail (printf "acl.users: duplicate username %q" .username) }}{{ end }}
{{- $_ := set $seen .username true }}
{{- if not $.Values.acl.existingSecret }}
{{- if not (get (default dict $.Values.aclPasswords) $key) }}
{{- fail (printf "no password for ACL user %q: set aclPasswords.%s in values-secrets.yaml or use acl.existingSecret" .username $key) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.httpApi.bearerToken.enabled (not .Values.httpApi.bearerToken.existingSecret) (not .Values.httpApiBearerToken) }}
{{- fail "httpApi.bearerToken.enabled=true: set httpApiBearerToken in values-secrets.yaml or httpApi.bearerToken.existingSecret (or disable it)" }}
{{- end }}
{{- if and .Values.tls.mutualTls (not .Values.tls.existingSecret) }}{{ fail "tls.mutualTls requires tls.existingSecret" }}{{ end }}
{{- end }}
