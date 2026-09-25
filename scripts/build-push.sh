#!/usr/bin/env bash
set -euo pipefail

#
# build-push.sh — Build the 8 microservice images for ARM64 and push them to ECR
#
# Two stages. Maven's buildDocker profile is deliberately NOT used:
#   1. Maven builds the executable JARs         ./mvnw clean package -DskipTests
#   2. docker buildx builds linux/arm64 images  (required: EKS nodes are Graviton t4g)
#      from the app repo's shared docker/Dockerfile and pushes each one straight to
#      {account}.dkr.ecr.{region}.amazonaws.com/petclinic-{env}/{service}:{tag}
#
# The app repo is treated as read-only: only its gitignored target/ directories are
# written. On an x86 host, buildx needs QEMU emulation for arm64 (Docker Desktop
# includes it). Requires: aws, docker (running, with buildx), and JDK 17+.
#
# Usage:
#   ./scripts/build-push.sh [--env dev] [--tag v1.0.0] [--region eu-central-1]
#                           [--app-dir <path>] [--skip-maven]
#
# Manual equivalent for a single service (from the app repo root):
#   ./mvnw -B clean package -DskipTests
#   mkdir ctx && cp spring-petclinic-customers-service/target/spring-petclinic-customers-service-*.jar ctx/app.jar
#   docker buildx build --platform linux/arm64 --provenance=false --push \
#     -f docker/Dockerfile --build-arg ARTIFACT_NAME=app --build-arg EXPOSED_PORT=8081 \
#     -t {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-dev/customers-service:v1.0.0 ctx
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV="dev"
TAG="v1.0.0"
REGION="eu-central-1"
APP_DIR="${SCRIPT_DIR}/../../spring-petclinic-microservices"
SKIP_MAVEN=false
PLATFORM="linux/arm64"

# Startup order: config-server and discovery-server first.
SERVICES="config-server discovery-server api-gateway customers-service visits-service vets-service genai-service admin-server"

# Runtime ports from the technical spec's service inventory. The
# docker.image.exposed.port values in the app's poms are wrong for several
# services, so they are not used.
service_port() {
  case "$1" in
    config-server)     echo 8888 ;;
    discovery-server)  echo 8761 ;;
    api-gateway)       echo 8080 ;;
    customers-service) echo 8081 ;;
    visits-service)    echo 8082 ;;
    vets-service)      echo 8083 ;;
    genai-service)     echo 8084 ;;
    admin-server)      echo 9090 ;;
    *)
      echo "Unknown service: $1" >&2
      return 1
      ;;
  esac
}

usage() {
  echo "Usage: $0 [--env dev|prod] [--tag <tag>] [--region <aws-region>] [--app-dir <path>] [--skip-maven]"
  echo ""
  echo "  --env         Target environment; repos are petclinic-{env}/{service} (default: dev)"
  echo "  --tag         Image tag, e.g. v1.0.0 or a short commit SHA; 'latest' is rejected (default: v1.0.0)"
  echo "  --region      AWS region of the ECR registry (default: eu-central-1)"
  echo "  --app-dir     Path to the spring-petclinic-microservices checkout (default: ../spring-petclinic-microservices)"
  echo "  --skip-maven  Reuse JARs already built in each module's target/ directory"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || usage
      ENV="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || usage
      TAG="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || usage
      REGION="$2"
      shift 2
      ;;
    --app-dir)
      [[ $# -ge 2 ]] || usage
      APP_DIR="$2"
      shift 2
      ;;
    --skip-maven)
      SKIP_MAVEN=true
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

if [[ "${ENV}" != "dev" && "${ENV}" != "prod" ]]; then
  echo "Error: --env must be 'dev' or 'prod'"
  exit 1
fi

TAG_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
if [[ "${TAG}" == "latest" ]]; then
  echo "Error: the 'latest' tag is not allowed — use a semantic version or a short commit SHA"
  exit 1
fi
if ! [[ "${TAG}" =~ ${TAG_RE} ]]; then
  echo "Error: '${TAG}' is not a valid image tag"
  exit 1
fi

if ! APP_DIR="$(cd "${APP_DIR}" 2>/dev/null && pwd)"; then
  echo "Error: app repo not found. Pass --app-dir <path to spring-petclinic-microservices>."
  exit 1
fi
if [[ ! -x "${APP_DIR}/mvnw" || ! -f "${APP_DIR}/docker/Dockerfile" ]]; then
  echo "Error: ${APP_DIR} does not look like spring-petclinic-microservices (missing mvnw or docker/Dockerfile)."
  exit 1
fi

# --- Preflight: fail early, before a long Maven build ---
for tool in aws docker; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "Error: '${tool}' is required but was not found in PATH."
    exit 1
  fi
done
if ! docker info > /dev/null 2>&1; then
  echo "Error: cannot reach the Docker daemon. Start Docker (Desktop or dockerd) and retry."
  exit 1
fi
if ! docker buildx version > /dev/null 2>&1; then
  echo "Error: docker buildx is not available."
  exit 1
fi
if ! docker buildx inspect --bootstrap 2> /dev/null | grep -q "${PLATFORM}"; then
  echo "Error: the active buildx builder cannot target ${PLATFORM}. Register QEMU emulation with:"
  echo "  docker run --privileged --rm tonistiigi/binfmt --install arm64"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "============================================"
echo "  Build & push images"
echo "  Account:  ${ACCOUNT_ID}"
echo "  Registry: ${REGISTRY}"
echo "  Repos:    petclinic-${ENV}/{service}"
echo "  Tag:      ${TAG}"
echo "  Platform: ${PLATFORM}"
echo "  App repo: ${APP_DIR}"
echo "============================================"
echo ""

# --- Stage 1: JARs ---
if [[ "${SKIP_MAVEN}" == "true" ]]; then
  echo "[1/3] --skip-maven set — reusing existing JARs."
else
  echo "[1/3] Building JARs with Maven (tests skipped)..."
  (cd "${APP_DIR}" && ./mvnw -B clean package -DskipTests)
fi
echo ""

# Each module must have produced exactly one executable JAR.
# (The *.jar glob does not match Spring Boot's *.jar.original.)
find_jar() {
  local svc="$1"
  local matches=("${APP_DIR}/spring-petclinic-${svc}/target/spring-petclinic-${svc}-"*.jar)
  if [[ ! -e "${matches[0]}" ]]; then
    echo "Error: no JAR found for ${svc} in ${APP_DIR}/spring-petclinic-${svc}/target/" >&2
    return 1
  fi
  if [[ ${#matches[@]} -ne 1 ]]; then
    echo "Error: expected one JAR for ${svc}, found ${#matches[@]}: ${matches[*]}" >&2
    return 1
  fi
  echo "${matches[0]}"
}

for svc in ${SERVICES}; do
  find_jar "${svc}" > /dev/null
done

# --- Stage 2: ECR login ---
echo "[2/3] Authenticating Docker to ECR..."
"${SCRIPT_DIR}/ecr-login.sh" --region "${REGION}"
echo ""

# --- Stage 3: build + push ---
# The build context is a temp dir holding only the JAR (as app.jar), so buildx does
# not upload each module's whole target/ directory. The Dockerfile lives in the app repo.
CTX="$(mktemp -d)"
trap 'rm -rf "${CTX}"' EXIT

echo "[3/3] Building ${PLATFORM} images and pushing to ECR..."
for svc in ${SERVICES}; do
  port="$(service_port "${svc}")"
  image="${REGISTRY}/petclinic-${ENV}/${svc}:${TAG}"

  echo ""
  echo "--- ${svc} (port ${port}) -> ${image}"
  rm -f "${CTX}"/*
  cp "$(find_jar "${svc}")" "${CTX}/app.jar"

  # --provenance=false keeps the tag pointing at a single image manifest instead of
  # an index with an attestation manifest (which would show up as extra untagged
  # images in ECR and count against the lifecycle policy).
  docker buildx build \
    --platform "${PLATFORM}" \
    --provenance=false \
    --file "${APP_DIR}/docker/Dockerfile" \
    --build-arg ARTIFACT_NAME=app \
    --build-arg EXPOSED_PORT="${port}" \
    --tag "${image}" \
    --push \
    "${CTX}"
done

# --- Verify ---
echo ""
echo "============================================"
echo "  Verifying images in ECR"
echo "============================================"
FAILED=false
for svc in ${SERVICES}; do
  ref="${REGISTRY}/petclinic-${ENV}/${svc}:${TAG}"
  digest=$(aws ecr describe-images \
    --repository-name "petclinic-${ENV}/${svc}" \
    --image-ids imageTag="${TAG}" \
    --region "${REGION}" \
    --query 'imageDetails[0].imageDigest' \
    --output text)
  # Read the architecture back from the registry — a tag existing does not prove
  # the image is ARM64, and an amd64 image would crash-loop on the Graviton nodes.
  actual="$(docker buildx imagetools inspect "${ref}" --format '{{.Image.OS}}/{{.Image.Architecture}}')"
  printf '  %-20s %-12s %s\n' "${svc}" "${actual}" "${digest}"
  if [[ "${actual}" != "${PLATFORM}" ]]; then
    echo "  ERROR: ${ref} is ${actual}, expected ${PLATFORM}" >&2
    FAILED=true
  fi
done

echo ""
if [[ "${FAILED}" == "true" ]]; then
  echo "FAILED: one or more images are not ${PLATFORM}." >&2
  exit 1
fi
echo "Done. ${TAG} pushed for all services to ${REGISTRY}/petclinic-${ENV}/ (all ${PLATFORM})."
