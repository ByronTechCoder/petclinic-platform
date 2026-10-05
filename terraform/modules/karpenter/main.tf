# karpenter module — IAM, interruption queue, and instance profile for Karpenter
# node autoscaling (PETPLAT-73; technical-spec.md#karpenter-node-autoscaling).
# The Karpenter controller itself is installed via Helm (scripts/), and its
# NodePool/EC2NodeClass CRDs reference the instance profile this module creates.

locals {
  name_prefix           = "${var.project}-${var.environment}"
  instance_profile_name = "${local.name_prefix}-karpenter-node-profile"
  oidc_host             = replace(var.oidc_provider_url, "https://", "")
  node_role_name        = regex("[^/]+$", var.node_role_arn)
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- Controller IRSA role ---

data "aws_iam_policy_document" "controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${local.name_prefix}-karpenter-role"
  assume_role_policy = data.aws_iam_policy_document.controller_assume_role.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-karpenter-role"
  })
}

data "aws_iam_policy_document" "controller" {
  # Read-only discovery of EC2 capacity, subnets, SGs, AMIs, spot prices.
  statement {
    sid       = "EC2Describe"
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }

  # Launching capacity. RunInstances/CreateFleet cannot be scoped to resources
  # that don't exist yet, so the cluster tag condition is the boundary: anything
  # Karpenter creates must carry the cluster's ownership tag.
  statement {
    sid    = "EC2Provision"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  # Tagging at creation only: CreateTags is allowed solely as part of a launch
  # call (ec2:CreateAction), and only for the cluster's owner tag. A standalone
  # CreateTags call on an existing resource is denied by this statement.
  statement {
    sid       = "EC2TagOnCreate"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  # Post-launch tagging (e.g. Karpenter's NodeClaim tags) only on resources that
  # already carry the cluster owner tag. An unowned instance cannot be claimed
  # by adding the tag, which closes the self-tag-then-terminate path.
  statement {
    sid       = "EC2TagOwned"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  # Referenced resources (subnet, security group, AMI, network interface, volume)
  # carry no ownership tags, and the EC2NodeClass validation dry-run uses them
  # directly, so RunInstances is granted on those resource types without a tag condition.
  statement {
    sid     = "EC2RunInstancesReferences"
    effect  = "Allow"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:subnet/*",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:security-group/*",
      "arn:aws:ec2:${data.aws_region.current.name}::image/*",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-interface/*",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:volume/*",
    ]
  }

  # The EC2NodeClass validation performs a dry-run RunInstances, which is authorized
  # against the instance resource. Granting it only for dry-run calls lets validation
  # pass without allowing untagged instances to actually launch.
  statement {
    sid       = "EC2RunInstancesDryRunValidation"
    effect    = "Allow"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "Bool"
      variable = "ec2:DryRun"
      values   = ["true"]
    }
  }

  # Launching from an existing launch template Karpenter created. It is tagged
  # (not requested) with the cluster owner tag, so the boundary is the resource tag.
  statement {
    sid    = "EC2LaunchFromOwnedTemplate"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:launch-template/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  # Listing instance profiles only supports resource "*" in IAM.
  statement {
    sid       = "InstanceProfileList"
    effect    = "Allow"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["*"]
  }

  # Only instances and launch templates Karpenter owns (cluster tag) can be
  # terminated or deleted — not unrelated EC2 resources in the account.
  statement {
    sid    = "EC2ManageOwned"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  statement {
    sid       = "EKSDescribeCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }

  # The instance profile Karpenter attaches to the nodes it launches — scoped to
  # this environment's single profile, nothing else.
  statement {
    sid    = "InstanceProfileManage"
    effect = "Allow"
    actions = [
      "iam:GetInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${local.instance_profile_name}"]
  }

  # iam:PassRole is checked against the role, not the instance profile, so it is
  # scoped to the node role ARN (the role this profile wraps), and only for EC2.
  statement {
    sid       = "PassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.node_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid    = "InterruptionQueue"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:ReceiveMessage",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.interruption.arn]
  }

  # EKS-optimized AMI lookup via SSM public parameters.
  statement {
    sid       = "SSMAmiLookup"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}::parameter/aws/service/eks/*"]
  }

  statement {
    sid       = "PricingRead"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "controller" {
  name        = "${local.name_prefix}-karpenter-policy"
  description = "Least-privilege controller permissions for Karpenter in ${local.name_prefix}."
  policy      = data.aws_iam_policy_document.controller.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-karpenter-policy"
  })
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

# --- Instance profile for Karpenter-launched nodes ---

resource "aws_iam_instance_profile" "node" {
  name = local.instance_profile_name
  role = local.node_role_name

  tags = merge(var.tags, {
    Name = local.instance_profile_name
  })
}

# --- Spot interruption queue ---

resource "aws_sqs_queue" "interruption" {
  name                       = "${local.name_prefix}-karpenter-interruption"
  message_retention_seconds  = 300
  visibility_timeout_seconds = 1200
  sqs_managed_sse_enabled    = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-karpenter-interruption"
  })
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid     = "AllowEventBridge"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
    resources = [aws_sqs_queue.interruption.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values = [
        aws_cloudwatch_event_rule.spot_interruption.arn,
        aws_cloudwatch_event_rule.rebalance.arn,
        aws_cloudwatch_event_rule.state_change.arn,
        aws_cloudwatch_event_rule.scheduled_change.arn,
      ]
    }
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id
  policy    = data.aws_iam_policy_document.queue.json
}

# --- EventBridge rules routing EC2/Health events to the queue ---

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${local.name_prefix}-karpenter-spot-interruption"
  description = "Spot interruption warnings for Karpenter-managed nodes"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name        = "${local.name_prefix}-karpenter-rebalance"
  description = "Rebalance recommendations for Karpenter-managed nodes"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "state_change" {
  name        = "${local.name_prefix}-karpenter-state-change"
  description = "Instance state changes for Karpenter-managed nodes"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name        = "${local.name_prefix}-karpenter-scheduled-change"
  description = "AWS Health scheduled maintenance affecting Karpenter-managed nodes"
  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule = aws_cloudwatch_event_rule.rebalance.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_target" "state_change" {
  rule = aws_cloudwatch_event_rule.state_change.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule = aws_cloudwatch_event_rule.scheduled_change.name
  arn  = aws_sqs_queue.interruption.arn
}
