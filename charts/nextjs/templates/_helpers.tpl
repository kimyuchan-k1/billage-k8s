{{- define "nextjs.fullname" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nextjs.labels" -}}
app: {{ include "nextjs.fullname" . }}
app.kubernetes.io/name: {{ include "nextjs.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "nextjs.selectorLabels" -}}
app: {{ include "nextjs.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
