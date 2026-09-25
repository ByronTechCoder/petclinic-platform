# Outputs are added alongside each module call in main.tf as infrastructure is wired in.

output "vpc_id" {
  description = "ID of the prod VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the prod public subnets"
  value       = module.vpc.public_subnet_ids
}

output "eks_cluster_sg_id" {
  description = "ID of the prod EKS cluster (control plane) security group"
  value       = module.vpc.eks_cluster_sg_id
}

output "eks_node_sg_id" {
  description = "ID of the prod EKS worker node security group"
  value       = module.vpc.eks_node_sg_id
}

output "rds_sg_id" {
  description = "ID of the prod RDS security group"
  value       = module.vpc.rds_sg_id
}

output "alb_sg_id" {
  description = "ID of the prod ALB security group"
  value       = module.vpc.alb_sg_id
}

output "eks_cluster_name" {
  description = "Name of the prod EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "API server endpoint of the prod EKS cluster"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the prod EKS cluster"
  value       = module.eks.cluster_ca_certificate
}

output "eks_oidc_provider_arn" {
  description = "ARN of the prod EKS OIDC provider (for IRSA)"
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "URL of the prod EKS OIDC provider (for IRSA)"
  value       = module.eks.oidc_provider_url
}

output "eks_node_group_name" {
  description = "Name of the prod EKS managed node group"
  value       = module.eks.node_group_name
}

output "eks_node_role_arn" {
  description = "ARN of the prod EKS worker node IAM role"
  value       = module.eks.node_role_arn
}

output "eks_ebs_csi_role_arn" {
  description = "ARN of the prod IRSA role used by the aws-ebs-csi-driver add-on"
  value       = module.eks.ebs_csi_role_arn
}

output "eks_lb_controller_role_arn" {
  description = "ARN of the prod IRSA role for the AWS Load Balancer Controller (pass to scripts/install-lb-controller.sh)"
  value       = module.eks.lb_controller_role_arn
}

output "eks_eso_role_arn" {
  description = "ARN of the prod IRSA role for the External Secrets Operator (pass to scripts/install-eso.sh)"
  value       = module.eks.eso_role_arn
}

output "eks_kubeconfig_command" {
  description = "Command to update local kubeconfig for the prod EKS cluster"
  value       = module.eks.kubeconfig_command
}

output "ecr_repository_urls" {
  description = "Map of service name to prod ECR repository URL"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "Map of service name to prod ECR repository ARN"
  value       = module.ecr.repository_arns
}

output "rds_endpoint" {
  description = "Prod RDS endpoint hostname"
  value       = module.rds.endpoint
}

output "rds_port" {
  description = "Prod RDS port"
  value       = module.rds.port
}

output "rds_db_instance_id" {
  description = "Prod RDS instance identifier"
  value       = module.rds.db_instance_id
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN for prod RDS master credentials"
  value       = module.rds.secret_arn
}

output "rds_connection_string" {
  description = "Prod RDS JDBC connection string (no credentials)"
  value       = module.rds.connection_string
}

output "dns_zone_id" {
  description = "Route 53 hosted zone ID looked up for prod (and dev — shared zone)"
  value       = module.dns.zone_id
}

output "dns_name_servers" {
  description = "Name servers for the shared hosted zone"
  value       = module.dns.name_servers
}

output "dns_certificate_arn" {
  description = "ARN of the validated wildcard ACM certificate for prod (used in the Ingress certificate-arn annotation)"
  value       = module.dns.certificate_arn
}

output "dns_record_fqdn" {
  description = "Prod DNS record created for the ALB, once create_alb_alias_record is true"
  value       = try(aws_route53_record.alb_alias[0].fqdn, null)
}

output "secrets_openai_secret_arn" {
  description = "Secrets Manager ARN for the prod OpenAI API key"
  value       = module.secrets.openai_secret_arn
}
