{{/*
Standart Helm helper'ları: isim, label ve selector üretimi.
*/}}

{{- define "synergychat.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "synergychart.labels" -}}
app.kubernetes.io/name: {{ include "synergychat.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
