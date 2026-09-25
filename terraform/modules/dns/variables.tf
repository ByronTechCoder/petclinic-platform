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

variable "domain_name" {
  description = "Domain name of the existing Route 53 public hosted zone (e.g. \"example.com\"). The zone must already exist — Route 53 creates it automatically on domain registration; this module looks it up rather than creating it."
  type        = string
}
