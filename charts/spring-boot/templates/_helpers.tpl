{{/*
fullname: release 이름 기반
*/}}
{{- define "spring-boot.fullname" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
공통 labels
*/}}
{{- define "spring-boot.labels" -}}
app: {{ include "spring-boot.fullname" . }}
app.kubernetes.io/name: {{ include "spring-boot.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
selector labels (Deployment matchLabels용)
*/}}
{{- define "spring-boot.selectorLabels" -}}
app: {{ include "spring-boot.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
