#!/usr/bin/env bash
set -euo pipefail

#
# validate-helm.sh — Validate the generic Helm chart (PETPLAT-110).
#
# Runs `helm lint` once, then for all 8 services x both environments:
#   helm template {service} helm/petclinic-service/ -n petclinic-{env} \
#     -f helm-values/{service}.yaml -f helm-values/{env}.yaml
#   kubectl apply --dry-run=client -f <rendered output>
#
# `kubectl apply --dry-run=client` only checks syntactic/schema validity
# against the Kubernetes API types it knows about — it does NOT require a
# live cluster for plain Deployment/Service/ConfigMap/ServiceAccount/HPA/PDB
# resources (those are built into kubectl's client-side OpenAPI schema).
# This chart only renders those six kinds, so the whole script can run
# without kubectl pointed at any cluster.
#
# Usage:
#   ./scripts/validate-helm.sh [--keep-output]
#
#   --keep-output   Don't delete the rendered YAML files afterward (written
#                    under a mktemp directory, printed at the end either way)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/helm/petclinic-service"
VALUES_DIR="${REPO_ROOT}/helm-values"

SERVICES="config-server discovery-server api-gateway customers-service visits-service vets-service genai-service admin-server"
ENVIRONMENTS="dev prod"

KEEP_OUTPUT=false
if [[ "${1:-}" == "--keep-output" ]]; then
  KEEP_OUTPUT=true
fi

for tool in helm kubectl; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "Error: '${tool}' is required but was not found in PATH."
    exit 1
  fi
done

OUT_DIR="$(mktemp -d)"
if [[ "${KEEP_OUTPUT}" != "true" ]]; then
  trap 'rm -rf "${OUT_DIR}"' EXIT
fi

FAILED=0
PASSED=0
declare -a FAILURES=()

echo "============================================"
echo "  helm lint"
echo "============================================"
if helm lint "${CHART_DIR}" --set image.registry=placeholder --set image.repositorySuffix=placeholder; then
  echo "PASS: helm lint"
else
  echo "FAIL: helm lint"
  FAILURES+=("helm lint")
  FAILED=$((FAILED + 1))
fi
echo ""

for env in ${ENVIRONMENTS}; do
  for svc in ${SERVICES}; do
    echo "============================================"
    echo "  ${svc} (${env})"
    echo "============================================"

    rendered="${OUT_DIR}/${svc}-${env}.yaml"

    if ! helm template "${svc}" "${CHART_DIR}" \
      --namespace "petclinic-${env}" \
      -f "${VALUES_DIR}/${svc}.yaml" \
      -f "${VALUES_DIR}/${env}.yaml" \
      > "${rendered}" 2> "${OUT_DIR}/${svc}-${env}.err"; then
      echo "FAIL: helm template ${svc} (${env})"
      cat "${OUT_DIR}/${svc}-${env}.err"
      FAILURES+=("helm template: ${svc} (${env})")
      FAILED=$((FAILED + 1))
      continue
    fi
    echo "OK: helm template rendered $(grep -c '^kind:' "${rendered}") resource(s)"

    if kubectl apply --dry-run=client -f "${rendered}" > "${OUT_DIR}/${svc}-${env}.dryrun" 2>&1; then
      echo "OK: kubectl apply --dry-run=client"
      cat "${OUT_DIR}/${svc}-${env}.dryrun"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL: kubectl apply --dry-run=client (${svc}, ${env})"
      cat "${OUT_DIR}/${svc}-${env}.dryrun"
      FAILURES+=("kubectl dry-run: ${svc} (${env})")
      FAILED=$((FAILED + 1))
    fi
    echo ""
  done
done

echo "============================================"
echo "  Summary"
echo "============================================"
echo "Passed: ${PASSED}"
echo "Failed: ${FAILED}"
if [[ ${FAILED} -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - ${f}"
  done
fi
echo ""
echo "Rendered output: ${OUT_DIR}$( [[ "${KEEP_OUTPUT}" != "true" ]] && echo ' (will be deleted on exit — pass --keep-output to retain it)' )"

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
