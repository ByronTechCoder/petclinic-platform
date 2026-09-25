# rds module — RDS MySQL instance shared by the customers, visits, and vets services, plus its Secrets Manager credentials.
#
# One shared `petclinic` database on a single instance (ADR-0003) — each of the 3
# database-backed services runs its own schema.sql against it (PETPLAT-24). All-public
# subnet design (ADR-0001): the DB subnet group uses the VPC's public subnets, and the
# rds security group (EKS-node-only on 3306, passed in via security_group_id) is the
# access-control boundary, not network placement.

locals {
  name_prefix = "${var.project}-${var.environment}"
  db_id       = "${local.name_prefix}-mysql"

  # RDS master passwords may not contain '/', '"', '@', or a space (AWS restriction).
  # This charset excludes all four while still giving good special-character entropy.
  password_special_chars = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-db-subnet-group"
  })
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.name_prefix}-mysql8"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-mysql8"
  })
}

# --- Master credentials (PETPLAT-23) ---

resource "random_password" "master" {
  length           = 20
  special          = true
  override_special = local.password_special_chars
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name        = "petclinic/${var.environment}/rds-credentials"
  description = "RDS master credentials for ${local.db_id}"

  # 0 = delete immediately, no recovery window. Both dev and prod here get
  # `terraform destroy`'d daily to control cost and re-applied the next
  # session (tutorial project, not a real production workload) — any window
  # > 0 leaves the secret name "scheduled for deletion" and blocks the very
  # next day's `terraform apply` with a 400 from Secrets Manager.
  recovery_window_in_days = 0

  tags = merge(var.tags, {
    Name = "petclinic/${var.environment}/rds-credentials"
  })
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id

  secret_string = jsonencode({
    username = "petclinic"
    password = random_password.master.result
  })
}

# --- RDS instance ---

resource "aws_db_instance" "this" {
  identifier     = local.db_id
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.instance_class

  db_name  = "petclinic"
  username = "petclinic"
  password = random_password.master.result

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp2"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [var.security_group_id]

  # Security groups are the access-control boundary (ADR-0001), but a database
  # holding credentials/PII still gets defense-in-depth: never publicly reachable.
  publicly_accessible = false

  multi_az                  = var.multi_az
  backup_retention_period   = var.backup_retention_period
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.db_id}-final"
  deletion_protection       = var.deletion_protection

  tags = merge(var.tags, {
    Name = local.db_id
  })
}
