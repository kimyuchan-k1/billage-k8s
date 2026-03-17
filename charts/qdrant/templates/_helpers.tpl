{{- define "qdrant.fullname" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "qdrant.labels" -}}
app: {{ include "qdrant.fullname" . }}
app.kubernetes.io/name: {{ include "qdrant.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "qdrant.selectorLabels" -}}
app: {{ include "qdrant.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
