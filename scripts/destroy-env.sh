#!/usr/bin/env bash
set -euo pipefail

#
# destroy-env.sh — Full daily teardown for one environment: delete the
# Kubernetes-triggered AWS resources Terraform doesn't track first
# (scripts/pre-destroy-cleanup.sh), then terraform destroy, with automatic
# one-time recovery from the failure mode already hit in this project: an
# orphaned ALB security group left behind by a manually-deleted ALB,
# blocking terraform's VPC teardown with a DependencyViolation.
#
# This script is NOT run by Claude Code itself — the project's own
# block-destroy.sh hook forbids that regardless. Run it yourself, directly
# in your terminal, when it's time to pause work for the day.
#
# Usage:
#   ./scripts/destroy-env.sh --environment dev [--yes]
#
#   --yes   Pass -auto-approve to terraform destroy, skipping its
#           interactive confirmation prompt. Omit it (the default) to see
#           Terraform's own destroy plan and confirm manually — this is
#           irreversible, so that's the recommended way to run it.
#
# Ordering note: pre-destroy-cleanup.sh runs BEFORE terraform destroy, and
# that order matters. Deleting the Ingress first, while the EKS cluster and
# its AWS Load Balancer Controller are still running, is what lets the
# controller clean up the ALB (and its own security groups) it created.
# Running terraform destroy first would tear down the cluster — and the
# controller pod along with it — before it gets a chance to do that,
# orphaning the ALB exactly like a direct `aws elbv2 delete-load-balancer`
# does.
#
# That leaves one wrinkle: once the ALB is gone, aws_route53_record.alb_alias
# can't be planned normally, because it depends on data "aws_lb" "ingress"
# looking that ALB up by tag, and a data source with nothing to find is a
# hard error, not a silent no-op. Every terraform destroy call below passes
# -var="create_alb_alias_record=false" specifically to route around this: it
# makes that resource and its data source evaluate as zero instances for
# this operation, so Terraform destroys the existing instance from state
# without ever needing to re-read the (already-deleted) ALB.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT="petclinic"
ENVIRONMENT=""
REGION="eu-central-1"
AUTO_APPROVE=false

usage() {
  cat <<EOF
Usage: $0 --environment <dev|prod> [options]

  --environment   Deployment environment (dev or prod)
  --project       Project name prefix (default: ${PROJECT})
  --region        AWS region (default: ${REGION})
  --yes           Pass -auto-approve to terraform destroy (skips the
                   interactive confirmation prompt — irreversible, use with
                   care)
  -h, --help      Show this help

Example:
  $0 --environment dev
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      [[ $# -ge 2 ]] || usage
      ENVIRONMENT="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || usage
      PROJECT="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || usage
      REGION="$2"
      shift 2
      ;;
    --yes)
      AUTO_APPROVE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

if [[ -z "${ENVIRONMENT}" ]]; then
  echo "Error: --environment is required."
  usage
fi
if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Error: --environment must be 'dev' or 'prod'."
  exit 1
fi

ENV_DIR="${REPO_ROOT}/terraform/environments/${ENVIRONMENT}"
if [[ ! -d "${ENV_DIR}" ]]; then
  echo "Error: ${ENV_DIR} not found."
  exit 1
fi

CLUSTER_NAME="${PROJECT}-${ENVIRONMENT}"

for tool in aws terraform; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "Error: '${tool}' is required but was not found in PATH."
    exit 1
  fi
done

echo "############################################"
echo "# Destroying petclinic-${ENVIRONMENT}"
echo "############################################"
echo ""

# --- Step 1: clean up K8s-managed AWS resources first, while the cluster
# and its controllers are still alive to do it properly ---
"${SCRIPT_DIR}/pre-destroy-cleanup.sh" --environment "${ENVIRONMENT}" --project "${PROJECT}" --region "${REGION}"
echo ""

# --- Step 2: terraform destroy ---
cd "${ENV_DIR}"
terraform init -input=false > /dev/null

echo "Capturing the VPC ID before destroy, in case it's needed for recovery below..."
VPC_ID="$(terraform output -raw vpc_id 2> /dev/null || true)"

# See the ordering note at the top of this file for why this -var is always
# passed, regardless of what terraform.tfvars actually says.
DESTROY_ARGS=(-var="create_alb_alias_record=false")
if [[ "${AUTO_APPROVE}" == "true" ]]; then
  DESTROY_ARGS+=("-auto-approve")
fi

set +e
terraform destroy "${DESTROY_ARGS[@]}"
DESTROY_EXIT=$?
set -e

if [[ ${DESTROY_EXIT} -ne 0 ]]; then
  echo ""
  echo "terraform destroy exited with an error. Checking for the known"
  echo "orphaned-ALB-security-group failure mode (a VPC DependencyViolation)..."

  if [[ -z "${VPC_ID}" ]]; then
    echo "No VPC ID was captured (state may already be too far gone) — cannot auto-recover."
    echo "Find the VPC ID from the error above and inspect its security groups manually:"
    echo "  aws ec2 describe-security-groups --filters Name=vpc-id,Values=<vpc-id> --query 'SecurityGroups[].{Id:GroupId,Name:GroupName}'"
    exit "${DESTROY_EXIT}"
  fi

  echo "VPC: ${VPC_ID}"
  # Only ever targets security groups the AWS Load Balancer Controller
  # itself created and tagged for THIS cluster — never a blanket "every
  # non-default SG in the VPC" sweep, which would also match this
  # environment's real, still-in-use, Terraform-managed security groups
  # (petclinic-{env}-alb-sg, -eks-node-sg, etc.) and try to delete those
  # too. AWS's own DependencyViolation check refused those the one time
  # this was tried without the tag filter, so nothing was actually lost —
  # but the untargeted query itself was a bug, not a safety feature.
  ORPHAN_SGS="$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
    --query "SecurityGroups[].GroupId" --output text 2> /dev/null || true)"

  if [[ -z "${ORPHAN_SGS}" ]]; then
    echo "No AWS Load Balancer Controller-tagged security groups found in ${VPC_ID} — this doesn't look like the known failure mode."
    echo "Re-run 'terraform destroy' manually in ${ENV_DIR} once you've investigated the error above."
    exit "${DESTROY_EXIT}"
  fi

  echo "Found orphaned AWS Load Balancer Controller security group(s), tagged elbv2.k8s.aws/cluster=${CLUSTER_NAME}:"
  for sg in ${ORPHAN_SGS}; do
    aws ec2 describe-security-groups --region "${REGION}" --group-ids "${sg}" \
      --query 'SecurityGroups[0].{Id:GroupId,Name:GroupName,Desc:Description}' --output table
  done

  echo "Deleting them and retrying terraform destroy once..."
  for sg in ${ORPHAN_SGS}; do
    if aws ec2 delete-security-group --region "${REGION}" --group-id "${sg}"; then
      echo "  deleted ${sg}"
    else
      echo "  could not delete ${sg} — it may still be referenced by something; inspect manually"
    fi
  done

  echo ""
  echo "Retrying terraform destroy..."
  terraform destroy "${DESTROY_ARGS[@]}"
fi

echo ""
echo "############################################"
echo "# petclinic-${ENVIRONMENT} destroyed"
echo "############################################"
