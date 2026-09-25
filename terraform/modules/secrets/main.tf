# secrets module — Non-RDS application secrets in AWS Secrets Manager.
#
# RDS credentials are NOT managed here — they're created by the rds module
# (PETPLAT-23) as a single JSON secret. This module handles everything else.
#
# config-server/git-username and git-password (PETPLAT-33's "Optional" item)
# are intentionally not created: the config server points at a public GitHub
# repo (technical-spec.md#config-server-details), so no git credentials are
# needed. Add them here if the config repo ever becomes private.

resource "aws_secretsmanager_secret" "openai_api_key" {
  name        = "petclinic/${var.environment}/openai-api-key"
  description = "OpenAI API key for the genai-service (petclinic-${var.environment})"

  # 0 = delete immediately, no recovery window — matches the rds module's
  # rds_credentials secret: both dev and prod get destroyed daily to control
  # cost and re-applied the next session, and any window > 0 leaves the
  # secret name "scheduled for deletion", blocking that same day's re-apply.
  recovery_window_in_days = 0

  tags = merge(var.tags, {
    Name = "petclinic/${var.environment}/openai-api-key"
  })
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = var.openai_api_key
}
