# petclinic-prod root module
#
# Module calls (vpc, eks, ecr, rds, dns, secrets, observability) are added
# incrementally as each epic in docs/jira-backlog.md is implemented
# (E-2 VPC, E-3 EKS, E-4 ECR, E-5 RDS, E-6 DNS, E-7 Secrets, E-11 Observability).

locals {
  # Matches k8s/base/ingress/ingress.yaml's metadata.namespace/name exactly —
  # the AWS Load Balancer Controller tags the ALB it creates for this Ingress
  # with ingress.k8s.aws/stack = "{namespace}/{name}", which the data source
  # below uses to find it.
  ingress_namespace = "petclinic-prod"
  ingress_name      = "petclinic-ingress"
  # Per technical-spec.md#dns-and-ingress: prod record is petclinic.{domain}
  # (no "-prod" — the dev record is the one that gets the environment prefix).
  dns_record_name = "petclinic.${var.domain_name}"
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "../../modules/vpc"

  project             = var.project
  environment         = var.environment
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  availability_zones  = var.availability_zones
}

module "eks" {
  source = "../../modules/eks"

  project     = var.project
  environment = var.environment

  subnet_ids                = module.vpc.public_subnet_ids
  cluster_security_group_id = module.vpc.eks_cluster_sg_id
  node_security_group_id    = module.vpc.eks_node_sg_id

  kubernetes_version = var.kubernetes_version

  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size

  # The Terraform deployer's own principal already gets cluster-admin via
  # bootstrap_cluster_creator_admin_permissions. Grant the account root user
  # an access entry too, since it's a different IAM principal and the AWS
  # console/kubectl otherwise return "Unauthorized" for it. Note: using root
  # for day-to-day cluster access is against AWS best practice — prefer an
  # IAM role/user for real work.
  additional_access_entries = [
    {
      principal_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      policy_arn        = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
      access_scope_type = "cluster"
    },
  ]
}

module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment

  service_names        = var.service_names
  image_tag_mutability = var.ecr_image_tag_mutability

  # force_delete stays false (module default) for prod — repositories should
  # not be deletable while they still hold images, unlike dev.
}

module "rds" {
  source = "../../modules/rds"

  project     = var.project
  environment = var.environment

  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.vpc.rds_sg_id

  instance_class        = var.rds_instance_class
  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage
  multi_az              = false # single-AZ to save cost; enable Multi-AZ in a real production workload (ADR-0006)

  # backup_retention_period (30) and skip_final_snapshot (false) intentionally
  # diverge from technical-spec.md's RDS Database table, which lists 7 days /
  # true for both envs. PETPLAT-22 and PETPLAT-27's acceptance criteria
  # explicitly call for 30-day retention and a retained final snapshot in
  # prod — a stricter, safer setting than dev gets, matching how this backlog
  # treats prod more conservatively elsewhere (e.g. ECR: IMMUTABLE tags and
  # force_delete=false in prod vs MUTABLE/true in dev). Followed the ticket
  # here as the more specific, more recently written source; worth
  # reconciling technical-spec.md's table to match in a follow-up.
  backup_retention_period = var.rds_backup_retention_period
  skip_final_snapshot     = false
  deletion_protection     = false
}

module "dns" {
  source = "../../modules/dns"

  project     = var.project
  environment = var.environment

  domain_name = var.domain_name
}

module "secrets" {
  source = "../../modules/secrets"

  project     = var.project
  environment = var.environment

  openai_api_key = var.openai_api_key
}

# --- ALB alias record (PETPLAT-31) ---
# The AWS Load Balancer Controller (installed via scripts/install-lb-controller.sh,
# see the eks module's lb_controller_role_arn output) provisions the ALB when
# k8s/base/ingress/ingress.yaml is applied. The data lookup below only
# resolves once that ALB exists, so it — and the alias record — stay gated
# behind var.create_alb_alias_record (default false) to avoid breaking
# `terraform plan` for the whole environment before the controller/Ingress
# are deployed. Flip it to true and re-apply once the Ingress is live.
data "aws_lb" "ingress" {
  count = var.create_alb_alias_record ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
    "ingress.k8s.aws/stack" = "${local.ingress_namespace}/${local.ingress_name}"
  }
}

resource "aws_route53_record" "alb_alias" {
  count = var.create_alb_alias_record ? 1 : 0

  zone_id = module.dns.zone_id
  name    = local.dns_record_name
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress[0].dns_name
    zone_id                = data.aws_lb.ingress[0].zone_id
    evaluate_target_health = true
  }
}

# --- Karpenter node autoscaling (PETPLAT-73) ---
module "karpenter" {
  source = "../../modules/karpenter"

  project           = var.project
  environment       = var.environment
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  node_role_arn     = module.eks.node_role_arn
}

# --- Monthly cost budget with email alerts at 50/80/100% of actual spend (PETPLAT-75) ---
# Dev and prod share one AWS account, so the budget filters on the
# Environment=prod cost-allocation tag. That tag must be activated in the
# Billing console (Cost allocation tags) before the filter matches anything.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Environment$prod"]
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}
