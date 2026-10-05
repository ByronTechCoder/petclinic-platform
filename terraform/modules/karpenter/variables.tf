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

variable "cluster_name" {
  description = "EKS cluster name Karpenter manages nodes for"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN (module.eks.oidc_provider_arn) — the IRSA trust policy federates through this"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL (module.eks.oidc_provider_url), with or without the https:// prefix"
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for Karpenter-launched nodes (module.eks.node_role_arn). The instance profile wraps this role."
  type        = string
}

variable "tags" {
  description = "Additional tags to merge into resources created by this module"
  type        = map(string)
  default     = {}
}
