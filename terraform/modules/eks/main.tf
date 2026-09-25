# eks module — EKS cluster, managed node group, OIDC provider for IRSA, and supporting IAM roles.
#
# All-public subnet design (see ADR-0001): the cluster and node group run in the
# public subnets from the vpc module; the eks_cluster/eks_node security groups
# created there are the access-control boundary.

locals {
  name_prefix     = "${var.project}-${var.environment}"
  cluster_name    = local.name_prefix
  node_group_name = "${local.name_prefix}-nodes"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- Cluster IAM role ---

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name_prefix}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eks-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Control plane log group ---
# Created explicitly (rather than left to EKS to auto-create) so retention is
# bounded instead of defaulting to "never expire".

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eks-cluster-logs"
  })
}

# --- EKS cluster ---

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [var.cluster_security_group_id]
    endpoint_public_access  = true
    endpoint_private_access = false
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = merge(var.tags, {
    Name = local.cluster_name
  })

  depends_on = [aws_iam_role_policy_attachment.cluster_policy, aws_cloudwatch_log_group.eks_cluster]
}

# --- OIDC provider for IRSA ---

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eks-oidc"
  })
}

# --- Additional EKS access entries (beyond the cluster creator) ---
# See the additional_access_entries variable description for how to grant
# another IAM user/role kubectl access.

resource "aws_eks_access_entry" "additional" {
  for_each = { for entry in var.additional_access_entries : entry.principal_arn => entry }

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
}

resource "aws_eks_access_policy_association" "additional" {
  for_each = { for entry in var.additional_access_entries : entry.principal_arn => entry }

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type = each.value.access_scope_type
  }

  depends_on = [aws_eks_access_entry.additional]
}

# --- Node IAM role ---

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name_prefix}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eks-node-role"
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# --- Node launch template ---
# A plain aws_eks_node_group has no security_group_ids argument — without a
# custom launch template, AWS silently auto-attaches its own EKS-generated
# cluster security group to the node instances instead of the node SG we
# actually pass in (var.node_security_group_id), which the RDS/ALB SG rules
# specifically reference. This launch template is what makes those rules
# actually take effect on the real node ENIs. Root device name (/dev/xvda) is
# fixed across both AL2 and AL2023 EKS-optimized AMIs, x86 and ARM64 alike.
resource "aws_launch_template" "node" {
  name_prefix = "${local.node_group_name}-"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Setting security_groups here stops EKS from auto-attaching its own
  # cluster SG. Include our own cluster SG alongside the node SG so
  # control-plane<->node traffic keeps working exactly as the vpc module's
  # cluster_from_nodes/node_from_cluster rules were designed to allow.
  network_interfaces {
    security_groups       = [var.node_security_group_id, var.cluster_security_group_id]
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required" # enforce IMDSv2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = local.node_group_name })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${local.node_group_name}-volume" })
  }

  tags = merge(var.tags, { Name = "${local.node_group_name}-lt" })

  lifecycle {
    create_before_destroy = true
  }
}

# --- Managed node group ---

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_group_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  # disk_size moved into the launch template's block_device_mappings above —
  # the EKS API rejects setting both on a node group that uses a custom
  # launch template. ami_type stays here (no image_id in the launch
  # template) so EKS still auto-resolves the correct AMI per kubernetes_version.
  ami_type       = var.node_ami_type
  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  node_repair_config {
    enabled = true
  }

  labels = merge({
    environment  = var.environment
    "managed-by" = "terraform"
  }, var.node_labels)

  dynamic "taint" {
    for_each = var.node_taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(var.tags, {
    Name = local.node_group_name
  })

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}

# --- EKS managed add-ons (PETPLAT-84) ---
# Versions pinned via variables — never "latest" — and conflicts resolved with
# OVERWRITE for initial setup. See variables.tf for the upgrade procedure.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = var.vpc_cni_version

  resolve_conflicts_on_create = "OVERWRITE"
  # OVERWRITE only applies to the initial create (PETPLAT-84); once the
  # add-on exists, PRESERVE avoids clobbering any manual/GitOps customization.
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(var.tags, { Name = "${local.name_prefix}-vpc-cni" })

  depends_on = [aws_eks_cluster.this]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = var.kube_proxy_version

  resolve_conflicts_on_create = "OVERWRITE"
  # OVERWRITE only applies to the initial create (PETPLAT-84); once the
  # add-on exists, PRESERVE avoids clobbering any manual/GitOps customization.
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(var.tags, { Name = "${local.name_prefix}-kube-proxy" })

  depends_on = [aws_eks_cluster.this]
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = var.coredns_version

  resolve_conflicts_on_create = "OVERWRITE"
  # OVERWRITE only applies to the initial create (PETPLAT-84); once the
  # add-on exists, PRESERVE avoids clobbering any manual/GitOps customization.
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(var.tags, { Name = "${local.name_prefix}-coredns" })

  # CoreDNS pods need a running node to schedule onto.
  depends_on = [aws_eks_node_group.this]
}

# --- EBS CSI driver IRSA role + add-on ---
# Required for PersistentVolumes used by Prometheus/Grafana (E-11 Observability).

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name_prefix}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-ebs-csi-role"
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = var.ebs_csi_driver_version
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  # OVERWRITE only applies to the initial create (PETPLAT-84); once the
  # add-on exists, PRESERVE avoids clobbering any manual/GitOps customization.
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(var.tags, { Name = "${local.name_prefix}-ebs-csi-driver" })

  # EBS CSI controller pods need a running node to schedule onto.
  depends_on = [aws_eks_node_group.this]
}

# --- AWS Load Balancer Controller IRSA role (PETPLAT-29) ---
# The controller itself is installed via Helm (scripts/install-lb-controller.sh),
# not Terraform — this only creates the IAM policy/role side of IRSA so the
# controller's ServiceAccount can assume it. Policy JSON is the upstream
# kubernetes-sigs/aws-load-balancer-controller v2.8.1 IAM policy, vendored
# as-is rather than hand-translated into HCL.

data "aws_iam_policy_document" "lb_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${local.name_prefix}-lb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume_role.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-lb-controller-role"
  })
}

resource "aws_iam_policy" "lb_controller" {
  name        = "${local.name_prefix}-lb-controller-policy"
  description = "Permissions required by the AWS Load Balancer Controller to manage ALBs/NLBs, target groups, and their security groups."
  policy      = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-lb-controller-policy"
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# --- External Secrets Operator IRSA role (PETPLAT-37) ---
# ESO itself is installed via Helm (scripts/install-eso.sh), not Terraform —
# this only creates the IAM side of IRSA so its ServiceAccount can read
# Secrets Manager. Scoped to secrets under petclinic/* only (least privilege,
# tighter than PETPLAT-37's literal arn:aws:secretsmanager:*:*:secret:petclinic/*
# — same intent, but this account/region are already known here). No
# kms:Decrypt statement: all secrets here use the default AWS-managed
# aws/secretsmanager key, whose resource policy already permits decryption
# for principals holding secretsmanager:GetSecretValue — a custom KMS key
# would need that grant, but nothing in this project uses one.

data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${local.name_prefix}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eso-role"
  })
}

data "aws_iam_policy_document" "eso_secrets_read" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:petclinic/*"]
  }
}

resource "aws_iam_policy" "eso" {
  name        = "${local.name_prefix}-eso-policy"
  description = "Permissions for the External Secrets Operator to read petclinic/* secrets from Secrets Manager."
  policy      = data.aws_iam_policy_document.eso_secrets_read.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eso-policy"
  })
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}
