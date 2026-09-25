# Baseline security groups (PETPLAT-8). These are the primary access control
# boundary in this all-public-subnet design — treat them like firewall rules.

resource "aws_security_group" "eks_cluster" {
  name        = "${local.name_prefix}-eks-cluster-sg"
  description = "EKS control plane security group for ${local.name_prefix}"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eks-cluster-sg"
  })
}

resource "aws_security_group" "eks_node" {
  name        = "${local.name_prefix}-eks-node-sg"
  description = "EKS worker node security group for ${local.name_prefix}"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eks-node-sg"
  })
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS MySQL security group for ${local.name_prefix}"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rds-sg"
  })
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB security group for ${local.name_prefix}"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb-sg"
  })
}

# --- EKS cluster (control plane) security group rules ---

resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes" {
  security_group_id            = aws_security_group.eks_cluster.id
  description                  = "API server access from EKS worker nodes"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "cluster_all_outbound" {
  security_group_id = aws_security_group.eks_cluster.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- EKS worker node security group rules ---

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "All traffic from the EKS cluster security group (includes kubelet API on 10250)"
  referenced_security_group_id = aws_security_group.eks_cluster.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "Inter-node communication"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_alb_nodeport" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "NodePort services reachable from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 30000
  to_port                      = 32767
}

resource "aws_vpc_security_group_ingress_rule" "node_from_alb_health_check" {
  security_group_id            = aws_security_group.eks_node.id
  description                  = "Health checks from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "node_all_outbound" {
  security_group_id = aws_security_group.eks_node.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- RDS security group rules ---
# Critical: MySQL is reachable from the EKS node SG only, never 0.0.0.0/0.

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL access from EKS worker nodes only"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# --- ALB security group rules ---

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_node_nodeport" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To EKS node target groups (NodePort range)"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 30000
  to_port                      = 32767
}

resource "aws_vpc_security_group_egress_rule" "alb_health_check" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Health checks to EKS nodes"
  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}
