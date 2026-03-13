{{/*
_helpers.tpl — Named Template Functions
===============================================================================
Named templates (defined with {{- define "..." -}}) are reusable snippets
called with {{ include "chartName.templateName" . }}.

The dot (.) passes the current scope (all values, release info, etc.).
You can also pass a specific value: {{ include "app.labels" .Values.userService }}

HELM TEMPLATE OBJECTS:
  .Values      → values.yaml (and overrides from --set / -f)
  .Release     → release metadata (.Release.Name, .Release.Namespace)
  .Chart       → Chart.yaml fields (.Chart.Name, .Chart.Version)
  .Capabilities → cluster capabilities (.Capabilities.KubeVersion)
  .Files       → access non-template files in the chart directory
  .Template    → current template file info (.Template.Name)

CONTROL FLOW:
  {{- ... -}}   Strips whitespace before (-) and after (-) the block.
                Important for clean YAML output.

  {{ if .Values.x }}...{{ end }}
  {{ range .Values.list }}...{{ end }}
  {{ with .Values.x }}...{{ end }}   (changes scope to .Values.x)

FUNCTIONS (Sprig library):
  default "fallback" .Values.x    → use fallback if x is empty
  required "msg" .Values.x        → fail template rendering if x is empty
  quote .Values.x                 → wrap in double quotes
  upper / lower / title           → string case
  toYaml .Values.resources        → render a map as YAML
  fromYaml / toJson               → type conversions
  include "tplName" .             → call named template and capture output
  tpl "{{ .Values.x }}" .         → render a string as a template (dynamic)
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "microservices-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated at 63 chars because Kubernetes limits label values to 63 characters.
*/}}
{{- define "microservices-app.fullname" -}}
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

{{/*
Create chart label.
*/}}
{{- define "microservices-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to ALL resources.
These are the recommended K8s label conventions:
  app.kubernetes.io/name     = name of the application (service)
  app.kubernetes.io/instance = name of the Helm release
  app.kubernetes.io/version  = app version
  app.kubernetes.io/component = role within the architecture
  helm.sh/chart              = chart name + version
  app.kubernetes.io/managed-by = "Helm"

Why labels matter:
  kubectl get pods -l app.kubernetes.io/instance=microservices
  → lists all pods from this release

  kubectl delete all -l helm.sh/chart=microservices-app-0.1.0
  → deletes all resources from chart version 0.1.0
*/}}
{{- define "microservices-app.labels" -}}
helm.sh/chart: {{ include "microservices-app.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels — used in Deployment.spec.selector and Service.spec.selector.
These MUST be stable (never change after first deploy) because selectors
are immutable on Deployments in K8s.
*/}}
{{- define "microservices-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .releaseName }}
{{- end }}

{{/*
Resolve image tag: use service-level tag if set, fall back to global.imageTag.
Usage: {{ include "microservices-app.imageTag" (dict "serviceTag" .Values.userService.image.tag "global" .Values.global) }}
*/}}
{{- define "microservices-app.imageTag" -}}
{{- coalesce .serviceTag .global.imageTag "latest" }}
{{- end }}

{{/*
Build the full image reference.
Usage: {{ include "microservices-app.image" (dict "registry" .Values.global.ecrRegistry "repo" .Values.userService.image.repository "tag" .tag) }}
*/}}
{{- define "microservices-app.image" -}}
{{- printf "%s/%s:%s" .registry .repo .tag }}
{{- end }}

{{/*
Render resource requests/limits block.
Avoids repeating the resources: block in every template.
Usage: {{- include "microservices-app.resources" .Values.userService.resources | nindent 12 }}
*/}}
{{- define "microservices-app.resources" -}}
{{- if . }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Render topology spread constraints.
Usage: {{- include "microservices-app.topologySpread" .Values.userService.topologySpreadConstraints | nindent 8 }}
*/}}
{{- define "microservices-app.topologySpread" -}}
{{- if . }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
