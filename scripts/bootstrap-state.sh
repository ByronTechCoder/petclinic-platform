#!/usr/bin/env bash
set -euo pipefail

#
# bootstrap-state.sh — One-time provisioning of the Terraform remote state backend
#
# Creates the S3 bucket (versioned, encrypted, fully private) and DynamoDB
# table (lock table) that terraform/environments/{dev,prod}/backend.tf point
# at. Run this once, before the first `terraform init`. Safe to re-run —
# every step checks current state before changing anything.
#
# Usage:
#   ./scripts/bootstrap-state.sh [--region eu-central-1]
#

REGION="eu-central-1"

usage() {
  echo "Usage: $0 [--region <aws-region>]"
  echo ""
  echo "  --region   AWS region to provision the state backend in (default: eu-central-1)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
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

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
BUCKET_NAME="petclinic-terraform-state-${ACCOUNT_ID}"
TABLE_NAME="petclinic-terraform-locks"

echo "============================================"
echo "  Terraform State Backend Bootstrap"
echo "  Account: ${ACCOUNT_ID}"
echo "  Region:  ${REGION}"
echo "  Bucket:  ${BUCKET_NAME}"
echo "  Table:   ${TABLE_NAME}"
echo "============================================"
echo ""

# --- S3 bucket ---
if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "[S3] Bucket ${BUCKET_NAME} already exists — skipping creation."
else
  echo "[S3] Creating bucket ${BUCKET_NAME}..."
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
fi

echo "[S3] Enabling versioning..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled \
  --region "${REGION}"

echo "[S3] Enabling default encryption (AES256)..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }
    ]
  }'

echo "[S3] Blocking all public access..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "[S3] Tagging bucket..."
aws s3api put-bucket-tagging \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --tagging 'TagSet=[{Key=Project,Value=petclinic},{Key=ManagedBy,Value=bootstrap-script}]'

echo ""

# --- DynamoDB lock table ---
if aws dynamodb describe-table --table-name "${TABLE_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "[DynamoDB] Table ${TABLE_NAME} already exists — skipping creation."
else
  echo "[DynamoDB] Creating table ${TABLE_NAME}..."
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Project,Value=petclinic Key=ManagedBy,Value=bootstrap-script \
    --region "${REGION}"

  echo "[DynamoDB] Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "${TABLE_NAME}" --region "${REGION}"
fi

echo ""
echo "============================================"
echo "  Bootstrap complete."
echo "  Next: cd terraform/environments/dev && terraform init"
echo "============================================"
