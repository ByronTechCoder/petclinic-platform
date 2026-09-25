#!/usr/bin/env bash
set -euo pipefail

#
# ecr-login.sh — Authenticate Docker to the private ECR registry
#
# Resolves your AWS account ID from the active credentials and logs Docker in to
# {account}.dkr.ecr.{region}.amazonaws.com. The token lasts 12 hours. Works on
# macOS and Linux (no GNU-only flags; compatible with macOS's bash 3.2).
#
# Usage:
#   ./scripts/ecr-login.sh [--region eu-central-1]
#

REGION="eu-central-1"

usage() {
  echo "Usage: $0 [--region <aws-region>]"
  echo ""
  echo "  --region   AWS region of the ECR registry (default: eu-central-1)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 ]] || usage
      REGION="$2"
      shift 2
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

for tool in aws docker; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "Error: '${tool}' is required but was not found in PATH."
    exit 1
  fi
done

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Logging in to ECR registry ${REGISTRY}..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"
