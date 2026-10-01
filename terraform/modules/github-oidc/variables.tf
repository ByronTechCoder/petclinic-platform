variable "github_org" {
  description = "GitHub org/username that owns the application repo fork (spring-petclinic-microservices). Must be the real value — derive it with `git remote get-url origin` in that repo, never hardcode a placeholder like \"{your-username}\"."
  type        = string

  validation {
    condition     = length(var.github_org) > 0
    error_message = "github_org must be a real GitHub username/org, not empty — see this variable's description for how to derive it."
  }
}

variable "github_repo" {
  description = "Application repo name the OIDC trust policy is scoped to. The build-push.yml workflow that assumes this role runs in this repo's context, not the platform repo's."
  type        = string
  default     = "spring-petclinic-microservices"
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
