#!/usr/bin/env bash
set -euo pipefail

#
# install-eso.sh — Install the External Secrets Operator on EKS (PETPLAT-34)
#
# Applies ESO's CRDs, adds/updates the external-secrets Helm repo, and
# helm-installs the operator into the external-secrets namespace, wired up
# to the IRSA role created by terraform/modules/eks (output: eso_role_arn).
# Finishes by applying the ClusterSecretStore so ExternalSecrets can
# immediately reference it.
#
# Usage:
#   ./scripts/install-eso.sh --environment dev [options]
#
# Requires: aws, kubectl (pointed at the target cluster), helm.
#

PROJECT="petclinic"
ENVIRONMENT=""
REGION="eu-central-1"
ROLE_ARN=""
CHART_VERSION="2.11.0" # external-secrets chart version == app version tag (v2.11.0) — unlike the LB controller, these match
NAMESPACE="external-secrets"
SERVICE_ACCOUNT="external-secrets-sa"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 --environment <dev|prod> [options]

  --environment      Deployment environment (dev or prod). Used to derive the
                      IRSA role name (petclinic-{env}-eso-role) unless overridden.
  --project           Project name prefix (default: ${PROJECT})
  --region            AWS region (default: ${REGION})
  --role-arn          Override the derived IRSA role ARN (skips the IAM lookup)
  --chart-version     external-secrets Helm chart version (default: ${CHART_VERSION})
  -h, --help          Show this help

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
    --role-arn)
      [[ $# -ge 2 ]] || usage
      ROLE_ARN="$2"
      shift 2
      ;;
    --chart-version)
      [[ $# -ge 2 ]] || usage
      CHART_VERSION="$2"
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

if [[ -z "${ENVIRONMENT}" ]]; then
  echo "Error: --environment is required."
  usage
fi

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Error: --environment must be 'dev' or 'prod'."
  exit 1
fi

for tool in aws kubectl helm; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "Error: '${tool}' is required but was not found in PATH."
    exit 1
  fi
done

if [[ -z "${ROLE_ARN}" ]]; then
  ROLE_NAME="${PROJECT}-${ENVIRONMENT}-eso-role"
  echo "Looking up IRSA role ${ROLE_NAME}..."
  ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)
fi

echo "Environment:    ${ENVIRONMENT}"
echo "Namespace:      ${NAMESPACE}"
echo "IRSA role ARN:  ${ROLE_ARN}"
echo "Chart version:  ${CHART_VERSION}"
echo ""

CRD_URL="https://raw.githubusercontent.com/external-secrets/external-secrets/v${CHART_VERSION}/deploy/crds/bundle.yaml"

echo "Applying CRDs from v${CHART_VERSION}..."
kubectl apply -f "${CRD_URL}" --server-side

echo "Adding/updating the external-secrets Helm repo..."
helm repo add external-secrets https://charts.external-secrets.io > /dev/null 2>&1 || true
helm repo update external-secrets

echo "Installing external-secrets (chart ${CHART_VERSION}) into namespace ${NAMESPACE}..."
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "${NAMESPACE}" --create-namespace \
  --version "${CHART_VERSION}" \
  --set installCRDs=false \
  --set serviceAccount.name="${SERVICE_ACCOUNT}" \
  --set-string serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${ROLE_ARN}"

echo "Waiting for the operator's deployments to become available..."
kubectl wait --for=condition=Available deployment --all -n "${NAMESPACE}" --timeout=180s

echo "Applying the ClusterSecretStore..."
kubectl apply -f "${REPO_ROOT}/k8s/base/external-secrets/cluster-secret-store.yaml"

echo ""
echo "Done. Verify with:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get clustersecretstore aws-secrets-manager -o wide"
echo ""
echo "Test with the openai-api-key ExternalSecret once the petclinic-${ENVIRONMENT}"
echo "namespace exists (E-8):"
echo "  kubectl apply -f k8s/base/external-secrets/openai-api-key.yaml"
echo "  kubectl get secret openai-api-key -n petclinic-${ENVIRONMENT}"
echo ""
echo "--- How to add a new secret (PETPLAT-34 documentation requirement) ---"
echo "1. Add the secret value to Secrets Manager: extend terraform/modules/secrets"
echo "   (or the rds module, for DB-adjacent secrets) with a new"
echo "   aws_secretsmanager_secret + aws_secretsmanager_secret_version resource"
echo "   pair, named petclinic/{env}/<your-secret>. Never hardcode the value —"
echo "   accept it as a sensitive Terraform variable. terraform apply it."
echo "2. Create an ExternalSecret manifest under k8s/base/external-secrets/,"
echo "   modeled on rds-credentials.yaml or openai-api-key.yaml: set"
echo "   secretStoreRef to {name: aws-secrets-manager, kind: ClusterSecretStore},"
echo "   and data[].remoteRef.key to petclinic/{env}/<your-secret>"
echo "   (with .property for a JSON secret, omitted for a plaintext one)."
echo "3. kubectl apply the manifest into the target namespace."
echo "4. Verify: kubectl get secret <target.name> -n <namespace> -o yaml"
echo "   (values are base64-encoded, not decrypted, in that output)."
