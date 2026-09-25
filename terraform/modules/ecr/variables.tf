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

variable "service_names" {
  description = "Service names to create one ECR repository each for, created as {project}-{environment}/{service_name}"
  type        = list(string)

  validation {
    condition     = length(var.service_names) > 0
    error_message = "service_names must contain at least one service name."
  }

  validation {
    condition     = alltrue([for name in var.service_names : can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", name))])
    error_message = "Each service name must be lowercase alphanumeric, optionally separated by single '.', '_' or '-' characters (ECR repository naming rules)."
  }
}

variable "image_tag_mutability" {
  description = "Tag mutability for the repositories: MUTABLE (dev — allows re-pushing a tag) or IMMUTABLE (prod — deployed tags can never be overwritten)"
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be either \"MUTABLE\" or \"IMMUTABLE\"."
  }
}

variable "max_tagged_image_count" {
  description = "Number of most recent tagged images to keep per repository; older tagged images expire"
  type        = number
  default     = 10

  validation {
    condition     = var.max_tagged_image_count >= 1
    error_message = "max_tagged_image_count must be at least 1."
  }
}

variable "untagged_image_expiry_days" {
  description = "Days after push before an untagged image expires"
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_image_expiry_days >= 1
    error_message = "untagged_image_expiry_days must be at least 1."
  }
}

variable "force_delete" {
  description = "Allow terraform destroy to delete repositories that still contain images. Keep false for prod; enable in dev so pausing an environment by destroying it does not fail on non-empty repositories (destroying then deletes the images)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags to merge into resources created by this module"
  type        = map(string)
  default     = {}
}
