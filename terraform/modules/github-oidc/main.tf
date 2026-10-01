# github-oidc module — OIDC federation between GitHub Actions and AWS, so
# the application repo's build-push.yml (PETPLAT-49) can push images to ECR
# without long-lived IAM access keys (technical-spec.md#oidc-federation-no-long-lived-credentials).
#
# Account-wide, not per-environment: AWS allows only one IAM OIDC provider
# per unique provider URL per account, so this module must be called from
# exactly ONE environment root module (dev — see terraform/environments/dev/main.tf's
# comment), never from both dev and prod.
#
# REFERENCED, not created: a real `terraform apply` (2026-10-01) hit
# "EntityAlreadyExists" — this AWS account already has a
# token.actions.githubusercontent.com OIDC provider, created outside this
# project for a completely unrelated app (tagged Project=my-react-app,
# Environment=production). The provider itself is generic/account-wide (its
# URL, audience, and thumbprint are identical for every AWS account — only
# the IAM ROLE's trust policy, below, is project-specific), so this module
# looks it up via a data source and builds its own role/policy against it,
# rather than trying to own its lifecycle. Taking ownership via `terraform
# import` was deliberately rejected: this environment gets destroyed nightly
# (see memory: daily_destroy_cycle), and importing someone else's shared
# provider into this state would delete THEIR provider — breaking an
# unrelated project's CI — on this project's next teardown.
#
# Scoped to the APPLICATION repo (spring-petclinic-microservices), not this
# platform repo — the build-push.yml workflow that assumes this role runs in
# the app repo's GitHub Actions context.

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github_actions" {
  arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    # Restricts to the app repo fork + branch only — not this platform repo,
    # not any other repo/branch. A bare "repo:{org}/{repo}:*" (any branch/PR)
    # would let a PR from a fork assume this role; pinning to
    # ref:refs/heads/{branch} closes that off.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "petclinic-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = merge(var.tags, {
    Name = "petclinic-github-actions-role"
  })
}

data "aws_iam_policy_document" "ecr_push" {
  # ecr:GetAuthorizationToken is account-wide by AWS design — it has no
  # resource-level permissions, so Resource "*" here is required, not a
  # least-privilege violation (see AWS docs for this action).
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push-only, scoped to this project's own ECR repos (var.ecr_repository_arns)
  # — no ecr:*, no "*". No pull/delete/describe actions: this role only needs
  # to push images it just built.
  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_policy" "ecr_push" {
  name        = "petclinic-github-actions-ecr-policy"
  description = "ECR push-only permissions for the GitHub Actions OIDC role (petclinic-github-actions-role)."
  policy      = data.aws_iam_policy_document.ecr_push.json

  tags = merge(var.tags, {
    Name = "petclinic-github-actions-ecr-policy"
  })
}

resource "aws_iam_role_policy_attachment" "ecr_push" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.ecr_push.arn
}
