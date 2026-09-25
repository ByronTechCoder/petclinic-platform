variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either \"dev\" or \"prod\"."
  }
}

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "vpc_cidr" {
  description = "CIDR block for the dev VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the dev public subnets, one per availability zone"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "availability_zones" {
  description = "Availability zones to spread the dev public subnets across"
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "kubernetes_version" {
  description = "Kubernetes version for the dev EKS cluster and managed node group"
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  description = "EC2 instance types for the dev managed node group (ARM64/Graviton free trial)"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "node_min_size" {
  description = "Minimum number of dev worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of dev worker nodes"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of dev worker nodes"
  type        = number
  default     = 2
}

variable "service_names" {
  description = "Microservices that each get a dev ECR repository (petclinic-dev/{service})"
  type        = list(string)
  default = [
    "config-server",
    "discovery-server",
    "api-gateway",
    "customers-service",
    "visits-service",
    "vets-service",
    "genai-service",
    "admin-server",
  ]
}

variable "ecr_image_tag_mutability" {
  description = "Tag mutability for dev ECR repositories (MUTABLE lets a tag be re-pushed during development)"
  type        = string
  default     = "MUTABLE"
}

variable "rds_instance_class" {
  description = "RDS instance class for dev (free tier)"
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "Initial RDS allocated storage in GB for dev"
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "Max RDS autoscale storage in GB for dev (equal to allocated_storage disables autoscaling, per free-tier sizing)"
  type        = number
  default     = 20
}

variable "rds_backup_retention_period" {
  description = "RDS automated backup retention in days for dev"
  type        = number
  default     = 7
}

variable "domain_name" {
  description = "Domain name of the existing Route 53 public hosted zone shared by dev and prod (e.g. \"example.com\"). Must already be registered — see terraform/modules/dns."
  type        = string
}

variable "create_alb_alias_record" {
  description = "Whether to create the Route 53 alias record (petclinic-dev.{domain_name}) pointing to the ALB. Leave false until scripts/install-lb-controller.sh has run and k8s/base/ingress/ingress.yaml is applied — the alias depends on a data lookup that only resolves once that ALB exists."
  type        = bool
  default     = false
}
