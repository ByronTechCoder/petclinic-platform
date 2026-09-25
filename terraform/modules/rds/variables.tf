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

variable "subnet_ids" {
  description = "Subnet IDs for the RDS DB subnet group (must span at least 2 AZs)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must contain at least 2 subnets spanning different AZs."
  }
}

variable "security_group_id" {
  description = "Security group ID to attach to the RDS instance (must allow 3306 from the EKS node SG only)"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial allocated storage in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Max autoscale storage in GB (storage autoscaling is disabled when equal to allocated_storage)"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Multi-AZ deployment (false for both envs — cost optimization; enable in a real production workload for HA)"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Automated backup retention in days (0 disables automated backups)"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 0 and 35 days (RDS maximum)."
  }
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on delete (true for dev — fast teardown; false for prod)"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable RDS deletion protection"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags to merge into resources created by this module"
  type        = map(string)
  default     = {}
}
