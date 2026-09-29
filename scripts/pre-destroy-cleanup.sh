#!/usr/bin/env bash
set -euo pipefail

#
# pre-destroy-cleanup.sh — Delete AWS resources that Kubernetes controllers
# created but Terraform doesn't track, before terraform destroy runs.
#
# Terraform only ever *looks up* the ALB via a data source (see
# terraform/environments/{env}/main.tf's data "aws_lb" "ingress") — it never
# creates or destroys one. The AWS Load Balancer Controller (and, if this
# project ever uses a dynamically-provisioned PersistentVolumeClaim, the EBS
# CSI driver) creates real AWS resources — ALBs, target groups, their
# security groups, EBS volumes — that only get cleaned up if you delete the
# *Kubernetes* object that caused them to be created (Ingress, LoadBalancer
# Service, PVC) while the controller managing them is still running.
# Destroying the EKS cluster out from under them (or deleting the ALB
# directly via the AWS API) orphans those companion resources — hit this
# exact failure once already: an orphaned ALB security group blocked a later
# `terraform destroy` on the VPC with a DependencyViolation.
#
# Usage:
#   ./scripts/pre-destroy-cleanup.sh --environment dev [--timeout 180]
#
# Safe to re-run and safe if the cluster is already gone (skips with a
# message rather than failing) — called automatically by destroy-env.sh, but
# fine to run standalone too.
#

PROJECT="petclinic"
ENVIRONMENT=""
REGION="eu-central-1"
TIMEOUT=180

usage() {
  cat <<EOF
Usage: $0 --environment <dev|prod> [options]

  --environment   Deployment environment (dev or prod)
  --project       Project name prefix (default: ${PROJECT})
  --region        AWS region (default: ${REGION})
  --timeout       Seconds to wait for each AWS-side resource to actually
                   disappear before giving up (default: ${TIMEOUT})
  -h, --help      Show this help
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
    --timeout)
      [[ $# -ge 2 ]] || usage
      TIMEOUT="$2"
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

CLUSTER_NAME="${PROJECT}-${ENVIRONMENT}"

for tool in aws kubectl; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "Error: '${tool}' is required but was not found in PATH."
    exit 1
  fi
done

echo "=== pre-destroy-cleanup: ${CLUSTER_NAME} ==="

# --- Point kubectl at the cluster, if it still exists ---
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" > /dev/null 2>&1; then
  echo "Cluster ${CLUSTER_NAME} doesn't exist (already destroyed?) — nothing to clean up here. Skipping."
  exit 0
fi

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" > /dev/null

if ! kubectl get nodes > /dev/null 2>&1; then
  echo "Warning: cluster ${CLUSTER_NAME} exists but is not reachable via kubectl."
  echo "Skipping K8s-side cleanup — check for orphaned ALBs/EBS volumes manually after terraform destroy."
  exit 0
fi

# --- 1. Ingresses -> ALBs + their security groups ---
INGRESSES="$(kubectl get ingress -A --no-headers 2> /dev/null | awk '{print $1"/"$2}')"
if [[ -n "${INGRESSES}" ]]; then
  echo "Deleting Ingress objects (lets the AWS Load Balancer Controller clean up its own ALB + security groups):"
  echo "${INGRESSES}"
  while read -r ns_name; do
    ns="${ns_name%%/*}"
    name="${ns_name##*/}"
    kubectl delete ingress "${name}" -n "${ns}" --wait=true --timeout="${TIMEOUT}s" || true
  done <<< "${INGRESSES}"

  echo "Waiting up to ${TIMEOUT}s for the controller-owned ALB(s) tagged for this cluster to actually disappear..."
  elapsed=0
  while true; do
    remaining="$(aws elbv2 describe-load-balancers --region "${REGION}" --query 'LoadBalancers[].LoadBalancerArn' --output text 2> /dev/null | tr '\t' '\n' | while read -r arn; do
      [[ -z "${arn}" ]] && continue
      tag="$(aws elbv2 describe-tags --region "${REGION}" --resource-arns "${arn}" --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" --output text 2> /dev/null)"
      [[ "${tag}" == "${CLUSTER_NAME}" ]] && echo "${arn}"
      true
    done)"
    if [[ -z "${remaining}" ]]; then
      echo "No ALBs tagged for ${CLUSTER_NAME} remain."
      break
    fi
    if [[ "${elapsed}" -ge "${TIMEOUT}" ]]; then
      echo "Warning: timed out after ${TIMEOUT}s waiting for the ALB to be deleted. Still present:"
      echo "${remaining}"
      echo "terraform destroy may hit a DependencyViolation on the VPC — if so, re-run this script, or delete the ALB and its security groups manually before retrying."
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
else
  echo "No Ingress objects found."
fi

# --- 2. LoadBalancer-type Services -> NLBs/ELBs ---
LB_SVCS="$(kubectl get svc -A --field-selector spec.type=LoadBalancer --no-headers 2> /dev/null | awk '{print $1"/"$2}')"
if [[ -n "${LB_SVCS}" ]]; then
  echo "Deleting LoadBalancer-type Services:"
  echo "${LB_SVCS}"
  while read -r ns_name; do
    ns="${ns_name%%/*}"
    name="${ns_name##*/}"
    kubectl delete svc "${name}" -n "${ns}" --wait=true --timeout="${TIMEOUT}s" || true
  done <<< "${LB_SVCS}"
  echo "Waiting 30s for the ELB/NLB controller to finish deprovisioning..."
  sleep 30
else
  echo "No LoadBalancer-type Services found."
fi

# --- 3. PVCs -> dynamically-provisioned EBS volumes ---
PVCS="$(kubectl get pvc -A --no-headers 2> /dev/null | awk '{print $1"/"$2}')"
if [[ -n "${PVCS}" ]]; then
  echo "Deleting PersistentVolumeClaims (releases their EBS volumes via the CSI driver's reclaim policy):"
  echo "${PVCS}"
  while read -r ns_name; do
    ns="${ns_name%%/*}"
    name="${ns_name##*/}"
    kubectl delete pvc "${name}" -n "${ns}" --wait=true --timeout="${TIMEOUT}s" || true
  done <<< "${PVCS}"
  echo "Waiting 15s for the EBS CSI driver to release the underlying volume(s)..."
  sleep 15
else
  echo "No PersistentVolumeClaims found."
fi

echo "=== pre-destroy-cleanup complete for ${CLUSTER_NAME} ==="
