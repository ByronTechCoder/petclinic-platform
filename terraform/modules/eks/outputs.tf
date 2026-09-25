output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the EKS cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version running on the EKS cluster"
  value       = aws_eks_cluster.this.version
}

output "cluster_iam_role_arn" {
  description = "ARN of the EKS cluster IAM role"
  value       = aws_iam_role.cluster.arn
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the IAM OIDC provider for IRSA (without the https:// prefix)"
  value       = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

output "node_group_name" {
  description = "Name of the EKS managed node group"
  value       = aws_eks_node_group.this.node_group_name
}

output "node_group_arn" {
  description = "ARN of the EKS managed node group"
  value       = aws_eks_node_group.this.arn
}

output "node_role_arn" {
  description = "ARN of the EKS worker node IAM role"
  value       = aws_iam_role.node.arn
}

output "ebs_csi_role_arn" {
  description = "ARN of the IRSA role used by the aws-ebs-csi-driver add-on"
  value       = aws_iam_role.ebs_csi.arn
}

output "lb_controller_role_arn" {
  description = "ARN of the IRSA role for the AWS Load Balancer Controller's ServiceAccount (kube-system/aws-load-balancer-controller)"
  value       = aws_iam_role.lb_controller.arn
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${data.aws_region.current.name}"
}
