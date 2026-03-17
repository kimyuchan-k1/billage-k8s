{{- define "rabbitmq.fullname" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rabbitmq.labels" -}}
app: {{ include "rabbitmq.fullname" . }}
app.kubernetes.io/name: {{ include "rabbitmq.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "rabbitmq.selectorLabels" -}}
app: {{ include "rabbitmq.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
