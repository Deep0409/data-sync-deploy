{{/* Chart name, cut to the 63 characters Kubernetes allows in a DNS label. */}}
{{- define "data-sync.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Name used for every resource. If the release name already contains the chart
name (e.g. release "data-sync"), don't repeat it, so we get plain "data-sync".
The kustomize overlay patches the Deployment by that name.
*/}}
{{- define "data-sync.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "data-sync.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels the Deployment and Service select on. Kubernetes doesn't allow a
Deployment's selector to change, so don't add labels here.
*/}}
{{- define "data-sync.selectorLabels" -}}
app.kubernetes.io/name: {{ include "data-sync.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "data-sync.labels" -}}
helm.sh/chart: {{ include "data-sync.chart" . }}
{{ include "data-sync.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: brightedge-platform
{{- end }}

{{- define "data-sync.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "data-sync.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Secret holding REDIS_PASSWORD: the externally managed one if secret.existingSecret
is set, otherwise the one this chart creates.
*/}}
{{- define "data-sync.secretName" -}}
{{- default (include "data-sync.fullname" .) .Values.secret.existingSecret }}
{{- end }}
