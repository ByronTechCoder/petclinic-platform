#!/usr/bin/env bash
set -euo pipefail

#
# destroy-env.sh — Full daily teardown for one environment: delete the
# Kubernetes-triggered AWS resources Terraform doesn't track first
# (scripts/pre-destroy-cleanup.sh), then terraform destroy, with automatic
# one-time recovery from the failure mode already hit twice in this
# project: an orphaned ALB security group left behind by a manually-deleted
# ALB, blocking `terraform destroy` on the VPC with a DependencyViolation.
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

# --- Step 1: clean up K8s-managed AWS resources first ---
"${SCRIPT_DIR}/pre-destroy-cleanup.sh" --environment "${ENVIRONMENT}" --project "${PROJECT}" --region "${REGION}"
echo ""

# --- Step 2: terraform destroy ---
cd "${ENV_DIR}"
terraform init -input=false > /dev/null

echo "Capturing the VPC ID before destroy, in case it's needed for recovery below..."
VPC_ID="$(terraform output -raw vpc_id 2> /dev/null || true)"

DESTROY_ARGS=()
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
  ORPHAN_SGS="$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2> /dev/null || true)"

  if [[ -z "${ORPHAN_SGS}" ]]; then
    echo "No non-default security groups found in ${VPC_ID} — this doesn't look like the known failure mode."
    echo "Re-run 'terraform destroy' manually in ${ENV_DIR} once you've investigated the error above."
    exit "${DESTROY_EXIT}"
  fi

  echo "Found non-default security group(s) in ${VPC_ID}, likely orphaned by a controller-managed ALB:"
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
