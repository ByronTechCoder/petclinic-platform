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

variable "subnet_ids" {
  description = "Subnet IDs for the EKS control plane and managed node group (public subnets — see ADR-0001)"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Security group ID attached to the EKS control plane (from the vpc module)"
  type        = string
}

variable "node_security_group_id" {
  description = "Security group ID attached to EKS worker nodes (from the vpc module)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster and managed node group. Must be a version currently offered by EKS in STANDARD_SUPPORT — check `aws eks describe-cluster-versions` before changing, since AWS retires old versions on its own schedule."
  type        = string
  default     = "1.34"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API server endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_log_retention_days" {
  description = "CloudWatch Logs retention (days) for the EKS control plane log group (api/audit/authenticator log types)"
  type        = number
  default     = 90
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Automatically grant the IAM principal that applies this module (e.g. the Terraform deployer) cluster-admin via an EKS access entry"
  type        = bool
  default     = true
}

# Additional users/roles that need kubectl access beyond the cluster creator:
# pass entries like
#   [{ principal_arn = "arn:aws:iam::<account>:role/platform-admins",
#      policy_arn     = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy",
#      access_scope_type = "cluster" }]
# and re-apply. See https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html
# for the available cluster-access-policy ARNs and access scope types.
variable "additional_access_entries" {
  description = "Additional EKS access entries (IAM principal -> access policy) for users/roles beyond the cluster creator"
  type = list(object({
    principal_arn     = string
    policy_arn        = string
    access_scope_type = string
  }))
  default = []
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group (ARM64/Graviton)"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "node_ami_type" {
  description = "AMI type for the managed node group. AL2 AMIs are only published through EKS 1.32 — AL2023_ARM_64_STANDARD is required for newer kubernetes_version values."
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "node_capacity_type" {
  description = "Capacity type for the managed node group (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"
}

variable "node_disk_size" {
  description = "Root EBS volume size (GB) for worker nodes"
  type        = number
  default     = 20
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_labels" {
  description = "Additional Kubernetes labels applied to worker nodes (merged with environment/managed-by)"
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Kubernetes taints applied to worker nodes"
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

# EKS add-on versions — pinned deliberately (never "latest") for reproducibility.
# To upgrade: run
#   aws eks describe-addon-versions --addon-name <name> --kubernetes-version <kubernetes_version>
# pick a version listed as compatible, update the matching variable below (or
# override via tfvars), then `terraform plan`/`apply`.
variable "coredns_version" {
  description = "Pinned version of the coredns EKS add-on (default matches the AWS-recommended default for kubernetes_version = 1.34, per `aws eks describe-addon-versions`)"
  type        = string
  default     = "v1.12.4-eksbuild.38"
}

variable "kube_proxy_version" {
  description = "Pinned version of the kube-proxy EKS add-on (default matches the AWS-recommended default for kubernetes_version = 1.34)"
  type        = string
  default     = "v1.34.6-eksbuild.29"
}

variable "vpc_cni_version" {
  description = "Pinned version of the vpc-cni EKS add-on (default matches the AWS-recommended default for kubernetes_version = 1.34)"
  type        = string
  default     = "v1.22.4-eksbuild.3"
}

variable "ebs_csi_driver_version" {
  description = "Pinned version of the aws-ebs-csi-driver EKS add-on (default matches the AWS-recommended default for kubernetes_version = 1.34)"
  type        = string
  default     = "v1.66.0-eksbuild.1"
}
