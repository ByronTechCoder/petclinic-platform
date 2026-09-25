output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.this.id
}

output "eks_cluster_sg_id" {
  description = "ID of the EKS cluster (control plane) security group"
  value       = aws_security_group.eks_cluster.id
}

output "eks_node_sg_id" {
  description = "ID of the EKS worker node security group"
  value       = aws_security_group.eks_node.id
}

output "rds_sg_id" {
  description = "ID of the RDS security group"
  value       = aws_security_group.rds.id
}

output "alb_sg_id" {
  description = "ID of the ALB security group"
  value       = aws_security_group.alb.id
}
