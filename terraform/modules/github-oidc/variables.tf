variable "github_sub_prefix" {
  description = <<-EOT
    The OIDC subject claim prefix for the application repo (spring-petclinic-microservices),
    i.e. everything in the "sub" claim before ":ref:refs/heads/{branch}". Must be the REAL
    value for this exact repo — derive it, never hardcode a placeholder or guess the plain
    "repo:{org}/{repo}" form:

      gh api repos/{org}/{repo}/actions/oidc/customization/sub --jq '.sub_claim_prefix'

    This is NOT always just "repo:{org}/{repo}". If the repo has "immutable subject claims"
    enabled (GitHub's default for newer repos — prevents subject-claim reuse via repo
    rename/transfer), the prefix instead embeds numeric org/repo IDs, e.g.
    "repo:{org}@{org_id}/{repo}@{repo_id}". A hardcoded name-based value will produce a
    trust policy that looks correct but silently never matches — confirmed live
    (2026-10-01): the plain name-based form failed with "Not authorized to perform
    sts:AssumeRoleWithWebIdentity" against this exact repo for this exact reason.
  EOT
  type        = string

  validation {
    condition     = length(var.github_sub_prefix) > 0
    error_message = "github_sub_prefix must be the real value for this repo, not empty — see this variable's description for how to derive it."
  }
}

variable "github_branch" {
  description = "Branch the OIDC trust policy's subject claim is scoped to — only workflow runs triggered from this branch can assume the role."
  type        = string
  default     = "main"
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the GitHub Actions role is allowed to push images to (least privilege — no ecr:* / Resource \"*\"). Pass module.ecr.repository_arns' values from the calling root module."
  type        = list(string)
}

variable "tags" {
  description = "Additional tags to merge into resources created by this module. This module's resources are account-wide (one GitHub OIDC provider per account), not per-environment — the caller should tag Environment accordingly (e.g. \"shared\") rather than \"dev\"/\"prod\"."
  type        = map(string)
  default     = {}
}
