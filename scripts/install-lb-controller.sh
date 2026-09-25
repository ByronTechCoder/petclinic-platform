#!/usr/bin/env bash
set -euo pipefail

#
# install-lb-controller.sh — Install the AWS Load Balancer Controller on EKS (PETPLAT-29)
#
# Installs the controller's CRDs, adds/updates the eks-charts Helm repo, and
# helm-installs aws-load-balancer-controller into kube-system, wired up to
# the IRSA role created by terraform/modules/eks (output: lb_controller_role_arn).
#
# IMPORTANT: CRDs are fetched using the controller's APPLICATION version tag
# (e.g. v2.8.1), not the Helm CHART version (e.g. 1.8.1) — they use different
# numbering schemes, and the chart version returns a 404 against the
# kubernetes-sigs/aws-load-balancer-controller repo's tags.
#
# Usage:
#   ./scripts/install-lb-controller.sh --environment dev [options]
#
# Requires: aws, kubectl (pointed at the target cluster), helm.
#

PROJECT="petclinic"
ENVIRONMENT=""
REGION="eu-central-1"
CLUSTER_NAME=""
ROLE_ARN=""
CONTROLLER_APP_VERSION="v2.8.1" # controller application version — used for CRDs
CHART_VERSION="1.8.1"           # aws-load-balancer-controller Helm chart version matching CONTROLLER_APP_VERSION
NAMESPACE="kube-system"
SERVICE_ACCOUNT="aws-load-balancer-controller"

usage() {
  cat <<EOF
Usage: $0 --environment <dev|prod> [options]

  --environment      Deployment environment (dev or prod). Used to derive the
                      EKS cluster name (petclinic-{env}) and IRSA role name
                      (petclinic-{env}-lb-controller-role) unless overridden below.
  --project           Project name prefix (default: ${PROJECT})
  --region            AWS region (default: ${REGION})
  --cluster-name      Override the derived EKS cluster name
  --role-arn          Override the derived IRSA role ARN (skips the IAM lookup)
  --app-version       Controller application version tag used for CRDs (default: ${CONTROLLER_APP_VERSION})
  --chart-version     aws-load-balancer-controller Helm chart version (default: ${CHART_VERSION})
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
    --cluster-name)
      [[ $# -ge 2 ]] || usage
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --role-arn)
      [[ $# -ge 2 ]] || usage
      ROLE_ARN="$2"
      shift 2
      ;;
    --app-version)
      [[ $# -ge 2 ]] || usage
      CONTROLLER_APP_VERSION="$2"
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

CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT}-${ENVIRONMENT}}"

if [[ -z "${ROLE_ARN}" ]]; then
  ROLE_NAME="${PROJECT}-${ENVIRONMENT}-lb-controller-role"
  echo "Looking up IRSA role ${ROLE_NAME}..."
  ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)
fi

# The controller falls back to EC2 instance metadata to discover the VPC ID
# when --set vpcId isn't given, and that lookup 401s from inside a pod's
# network namespace on nodes with the default IMDS hop limit (1) — pods
# crash-loop with "failed to introspect vpcID from EC2Metadata". Look it up
# from the cluster itself instead so the controller never needs IMDS at all.
echo "Looking up VPC ID for cluster ${CLUSTER_NAME}..."
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --query 'cluster.resourcesVpcConfig.vpcId' --output text)

echo "Cluster:        ${CLUSTER_NAME}"
echo "VPC:            ${VPC_ID}"
echo "Region:         ${REGION}"
echo "IRSA role ARN:  ${ROLE_ARN}"
echo "Chart version:  ${CHART_VERSION} (controller ${CONTROLLER_APP_VERSION})"
echo ""

CRD_URL="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${CONTROLLER_APP_VERSION}/helm/aws-load-balancer-controller/crds/crds.yaml"

echo "Applying CRDs from controller ${CONTROLLER_APP_VERSION}..."
kubectl apply -f "${CRD_URL}"

echo "Adding/updating the eks-charts Helm repo..."
helm repo add eks https://aws.github.io/eks-charts > /dev/null 2>&1 || true
helm repo update eks

echo "Installing aws-load-balancer-controller (chart ${CHART_VERSION}) into namespace ${NAMESPACE}..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name="${SERVICE_ACCOUNT}" \
  --set-string serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${ROLE_ARN}"

echo "Waiting for the controller deployment to roll out..."
kubectl rollout status deployment/aws-load-balancer-controller -n "${NAMESPACE}" --timeout=180s

echo "Verifying the 'alb' IngressClass was created by the chart..."
kubectl get ingressclass alb

echo ""
echo "Done. Verify end-to-end by applying an Ingress with ingressClassName: alb"
echo "(e.g. k8s/base/ingress/ingress.yaml) and confirming an ALB is provisioned:"
echo "  kubectl get ingress -A"
