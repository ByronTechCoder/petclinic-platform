{{/*
Resource base name. Unlike the stock `helm create` scaffold's fullname
helper (which suffixes the chart name to avoid collisions between multiple
releases of a generic chart), every release of THIS chart is always named
after the exact service it deploys (`helm install customers-service ...`,
see technical-spec.md#helm-install--upgrade-command) — so the release name
alone is already the correct, final resource name, matching k8s/base/'s
naming exactly.
*/}}
{{- define "petclinic-service.fullname" -}}
{{- .Values.nameOverride | default .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Namespace: .Values.namespace if set (helm-values/{dev,prod}.yaml sets it),
otherwise whatever -n/--namespace was passed to helm.
*/}}
{{- define "petclinic-service.namespace" -}}
{{- .Values.namespace | default .Release.Namespace }}
{{- end }}

{{/*
Standard labels — app.kubernetes.io/* per technical-spec.md#standard-labels-all-resources,
matching every resource already in k8s/base/ exactly (including
managed-by: Helm, which is now literally true for these resources).
*/}}
{{- define "petclinic-service.labels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.fullname" . }}
app.kubernetes.io/part-of: petclinic
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/component: {{ .Values.component }}
{{- end }}

{{/*
Selector labels — deliberately just app.kubernetes.io/name, matching
k8s/base/'s spec.selector.matchLabels exactly (not the 4-label full set,
since selectors must stay stable across chart label changes).
*/}}
{{- define "petclinic-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.fullname" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "petclinic-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- include "petclinic-service.fullname" . }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
