# ecr module — Private ECR repositories (one per microservice) with lifecycle policies, scan-on-push, and configurable tag immutability.
#
# Repositories are named {project}-{environment}/{service} (e.g. petclinic-dev/config-server)
# so dev and prod images are isolated in separate namespaces.

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.service_names)

  name                 = "${local.name_prefix}/${each.key}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}/${each.key}"
  })
}

# Rule priorities are evaluated lowest-first. Untagged images (e.g. layers orphaned
# when a MUTABLE tag is re-pushed) expire after a short window; tagged images are
# capped to the most recent N so storage cost stays bounded.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_image_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.max_tagged_image_count} tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.max_tagged_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
