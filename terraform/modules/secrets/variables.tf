variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either \"dev\" or \"prod\"."
  }
}

variable "tags" {
  description = "Additional tags to merge into resources created by this module"
  type        = map(string)
  default     = {}
}

variable "openai_api_key" {
  description = "OpenAI API key value for the genai-service, stored in Secrets Manager. Never hardcode this — pass it via TF_VAR_openai_api_key or an untracked *.tfvars file."
  type        = string
  sensitive   = true
}
