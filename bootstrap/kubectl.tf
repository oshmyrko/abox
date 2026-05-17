# ==========================================
# Secret
# ==========================================
variable "gemini_api_key" {
  description = "API key for Gemini"
  type        = string
  default     = "GEMINI_API_KEY_STUB"
}

resource "kubectl_manifest" "kagent_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: kagent
  YAML
}

resource "kubectl_manifest" "kagent_gemini_api_key" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Secret
    metadata:
      name: kagent-gemini-api-key
      namespace: kagent
    type: Opaque
    stringData:
      GEMINI_API_KEY: "${var.gemini_api_key}"
  YAML
}
