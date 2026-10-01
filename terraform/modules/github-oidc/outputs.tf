output "role_arn" {
  description = "ARN of the GitHub Actions OIDC role — set as the AWS_ROLE_ARN GitHub Secret in the application repo for aws-actions/configure-aws-credentials."
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (pre-existing in this AWS account, looked up — not created by this module, see main.tf)"
  value       = data.aws_iam_openid_connect_provider.github_actions.arn
}
