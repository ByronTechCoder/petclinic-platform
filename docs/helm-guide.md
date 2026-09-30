# Helm Chart Guide

**Last Updated:** 2026-09-30
**Purpose:** How the generic `helm/petclinic-service/` chart and `helm-values/` files work, and how to deploy, modify, or extend them.

## Table of Contents

- [Chart Structure](#chart-structure)
- [Values Hierarchy](#values-hierarchy)
- [Deploy a Service Manually](#deploy-a-service-manually)
- [Add a New Service](#add-a-new-service)
- [Change Resources, Replicas, or Environment Variables](#change-resources-replicas-or-environment-variables)
- [Validation](#validation)
- [Integration with ArgoCD](#integration-with-argocd)
- [Relationship to k8s/base and k8s/overlays](#relationship-to-k8sbase-and-k8soverlays)

## Chart Structure

One generic chart (`helm/petclinic-service/`) deploys all 8 Petclinic microservices — each service is a separate Helm **release**, all using the same chart, differentiated entirely by values.

```
helm/petclinic-service/
├── Chart.yaml
├── values.yaml              # Defaults common to every service
└── templates/
    ├── _helpers.tpl         # Name/label/namespace helpers
    ├── serviceaccount.yaml
    ├── configmap.yaml
    ├── service.yaml
    ├── deployment.yaml       # Probes, resources, env vars, init containers, securityContext
    ├── hpa.yaml              # Only renders if .Values.autoscaling.enabled
    └── pdb.yaml              # Only renders if .Values.podDisruptionBudget.enabled

helm-values/
├── config-server.yaml       # Per-service: port, env vars, init containers, prod-shaped replicas/HPA/PDB
├── discovery-server.yaml
├── api-gateway.yaml
├── customers-service.yaml
├── visits-service.yaml
├── vets-service.yaml
├── genai-service.yaml
├── admin-server.yaml
├── dev.yaml                 # Per-environment: namespace, image registry, forces replicas=1/HPA off/PDB off
└── prod.yaml                 # Per-environment: namespace, image registry only (see below for why)
```

Each release is named after the service it deploys (`helm install customers-service ...`), and the chart's `fullname` helper uses that release name directly as every resource's name — so `helm install customers-service` produces a Deployment/Service/ConfigMap/ServiceAccount all named `customers-service`, matching `k8s/base/customers-service/`'s naming exactly.

## Values Hierarchy

Three layers, merged in this order — **later files win** on any key both define:

```
helm/petclinic-service/values.yaml  <  helm-values/{service}.yaml  <  helm-values/{env}.yaml  <  --set flags
```

The one deliberate exception is **replica count, autoscaling, and Pod Disruption Budget settings**: each per-service file already carries that service's *production* numbers (since prod is the more detailed, more service-specific case — see `k8s/overlays/prod/` and `technical-spec.md`'s Prod Overlay / HPA / PDB tables). `helm-values/dev.yaml` then forces `replicaCount: 1`, `autoscaling.enabled: false`, and `podDisruptionBudget.enabled: false` as blanket overrides, since it's loaded last. `helm-values/prod.yaml` deliberately does **not** touch those three keys at all, letting each service's own prod-shaped values pass through untouched. Don't add `replicaCount`/`autoscaling`/`podDisruptionBudget` to `prod.yaml` — that would silently overwrite every service's correct, service-specific number with one wrong blanket value (e.g. giving `admin-server` 2 replicas and an HPA it was never supposed to have).

## Deploy a Service Manually

```bash
helm upgrade --install customers-service helm/petclinic-service/ \
  -n petclinic-dev \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml \
  --set image.tag=v1.0.0
```

Swap `dev.yaml`/`petclinic-dev` for `prod.yaml`/`petclinic-prod` to deploy to prod. Repeat once per service (8 separate `helm install`/`upgrade` invocations — there is no single "install everything" command by design, matching one release per service).

**RDS endpoint for the 3 database-backed services** (`customers-service`, `visits-service`, `vets-service`): their `SPRING_DATASOURCE_URL` in `helm-values/{service}.yaml` is a literal `{rds-endpoint}` placeholder — it changes on every `terraform destroy`/`apply` cycle, so it's never baked into a committed file. Pass the real value at install time:

```bash
helm upgrade --install customers-service helm/petclinic-service/ \
  -n petclinic-dev \
  -f helm-values/customers-service.yaml -f helm-values/dev.yaml \
  --set-string configMap.SPRING_DATASOURCE_URL="jdbc:mysql://$(cd terraform/environments/dev && terraform output -raw rds_endpoint):3306/petclinic"
```

## Add a New Service

1. Create `helm-values/{new-service}.yaml`. Copy the closest existing service (a service with no MySQL dependency, like `admin-server.yaml`, is the simplest starting point) and set: `image.repositorySuffix`, `component` (`server`|`service`|`gateway`|`admin`), `service.port`, `configMap` (at minimum `CONFIG_SERVER_URL`), `initContainers` (usually `wait-for-config-server` + `wait-for-discovery-server`), and that service's **production** `replicaCount`/`autoscaling`/`podDisruptionBudget` if it needs them — dev.yaml will force them down automatically.
2. Render and dry-run it: `./scripts/validate-helm.sh` (validates all 8 services × both envs, including the new one once its values file exists).
3. Once E-17 exists, add an ArgoCD `Application` CRD per environment — see [Integration with ArgoCD](#integration-with-argocd).

## Change Resources, Replicas, or Environment Variables

- **Resources** (CPU/memory requests+limits): override `resources:` in the service's values file, or `initContainerResources:` for the wait-for-* containers. Chart default (`values.yaml`) is `100m/500m` CPU, `128Mi/512Mi` memory — `api-gateway.yaml` is the one service that overrides CPU (`200m/1000m`).
- **Replica count**: set `replicaCount` in the service's values file (treated as that service's *prod* number — see [Values Hierarchy](#values-hierarchy)). Dev always gets 1, regardless.
- **Environment variables**:
  - Non-secret: add a key under `configMap:` in the service's values file — it becomes both a ConfigMap entry and, via `envFrom`, a container env var.
  - Secret-sourced: add an entry to `secretEnv:` (`name`, `secretName`, `secretKey`) — `secretName`/`secretKey` must match an existing K8s `Secret` (synced by External Secrets Operator — see `k8s/base/external-secrets/`). Never put a real secret value in a values file.
  - Arbitrary literal env var (rare — nothing currently uses this): add to `env:` as `{name, value}`.

## Validation

```bash
./scripts/validate-helm.sh
```

Runs `helm lint` once, then for all 8 services × both environments: `helm template` followed by `kubectl apply --dry-run=client` on the rendered output. Pass `--keep-output` to retain the rendered YAML (under a `mktemp -d` directory, printed at the end) instead of deleting it on exit.

## Integration with ArgoCD

Not yet built (E-17). Per `technical-spec.md`'s Application CRD template, each service gets one ArgoCD `Application` per environment (16 total) pointing at this chart with the matching two `-f` value files:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: customers-service-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/{your-username}/petclinic-platform.git
    targetRevision: main
    path: helm/petclinic-service
    helm:
      valueFiles:
        - ../../helm-values/customers-service.yaml
        - ../../helm-values/dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: petclinic-dev
  syncPolicy:
    automated:      # Dev only — prod omits this block and requires manual sync via the ArgoCD UI/CLI
      prune: true
      selfHeal: true
```

CI (GitHub Actions, E-10) pushes images to ECR and commits the new tag into the matching `helm-values/{service}.yaml`; ArgoCD picks up that Git change and syncs it — auto for dev, manual-approval for prod. GitHub Actions never runs `kubectl`/`helm` directly against the cluster.

## Relationship to k8s/base and k8s/overlays

This chart **replaces** `k8s/base/{service}/` + `k8s/overlays/{dev,prod}/` as the actual deployment mechanism for the 8 microservice Deployments/Services/ConfigMaps/ServiceAccounts/HPAs/PDBs — it was built directly from those manifests as the source of truth (E-8/E-9), and produces equivalent output. The `k8s/base/{service}/` directories themselves are left on disk as documented provenance, but `k8s/base/kustomization.yaml` and `k8s/overlays/{dev,prod}/kustomization.yaml` no longer reference them (trimmed as part of this epic, once this chart existed to replace them) — applying `k8s/overlays/{dev,prod}` today only touches the Ingress and the two ExternalSecrets, never the 8 services, so there's no double-management.

`k8s/base/namespaces.yaml`, `k8s/base/ingress/`, and `k8s/base/external-secrets/` are **not** part of this chart and stay Kustomize/plain-manifest-managed — they're cluster/cross-cutting resources (Namespaces, the shared ALB Ingress, ExternalSecrets/ClusterSecretStore), not one-per-service application resources, so folding them into this chart wouldn't fit its per-service-release model. Apply those the same way as before: `kubectl apply -f k8s/base/namespaces.yaml`, then `kubectl apply -k k8s/overlays/{dev,prod}` for the ingress/external-secrets pieces. `k8s/overlays/prod/hpa.yaml` was deleted — the chart's own `templates/hpa.yaml` (rendered per-service via `helm-values/{service}.yaml`'s `autoscaling` block) is now the only source of per-service HPAs.
