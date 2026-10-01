# Rollback Runbook

**Last Updated:** 2026-10-01
**Purpose:** How to roll back a bad deployment of any of the 8 Petclinic microservices, in dev or prod, using the GitOps-first mechanisms this platform is designed around, plus an emergency `kubectl` fallback. (PETPLAT-54) This runbook assumes you've already identified which service and deployment are bad — see `docs/technical-spec.md#observability` (Prometheus/Grafana dashboards, `PodRestartLoop`/`HighErrorRate` alerts) or `kubectl get pods -n petclinic-{env}` for obvious crash-looping to get there.

## Table of Contents

- [Status: ArgoCD Not Yet Deployed (E-17)](#status-argocd-not-yet-deployed-e-17)
- [Architecture](#architecture)
- [Procedure: GitOps Rollback (Git Revert)](#procedure-gitops-rollback-git-revert)
- [Procedure: ArgoCD Rollback (UI/CLI)](#procedure-argocd-rollback-uicli)
- [Procedure: Helm Rollback (Current Interim Mechanism)](#procedure-helm-rollback-current-interim-mechanism)
- [Procedure: Emergency kubectl rollout undo](#procedure-emergency-kubectl-rollout-undo)
- [Choosing Which Procedure to Use](#choosing-which-procedure-to-use)

## Status: ArgoCD Not Yet Deployed (E-17)

This repo's rollback design is GitOps-first: ArgoCD watches `helm-values/`, and rolling back means reverting a Git commit, not running imperative commands against the cluster. **As of this writing, ArgoCD itself has not been deployed yet** (E-17 is not started — there is no `k8s/argocd/` directory in this repo). Until E-17 lands:

- The [GitOps Rollback](#procedure-gitops-rollback-git-revert) and [ArgoCD Rollback](#procedure-argocd-rollback-uicli) procedures below describe the **target-state** process this platform is built toward. They're accurate to `docs/technical-spec.md#gitops-with-argocd` but cannot be exercised yet — there is no ArgoCD `Application` to sync.
- Until then, deployments happen via direct `helm upgrade --install` (as documented in `docs/helm-guide.md`), so the actionable rollback path **today** is [Helm Rollback](#procedure-helm-rollback-current-interim-mechanism).
- The [Emergency kubectl rollout undo](#procedure-emergency-kubectl-rollout-undo) fallback works regardless of whether ArgoCD exists — it operates directly on the Deployment object.
- PETPLAT-54's "tested: deploy bad image → git revert → ArgoCD syncs → service recovered" acceptance criterion is **not yet verifiable** for the same reason, and should be re-run once E-17 is complete.

## Architecture

```
Developer pushes code → build-push.yml builds + pushes ARM64 images to ECR
  → update-image-tags.yml commits new image.tag to helm-values/{service}.yaml
    → ArgoCD detects the Git change (once E-17 exists)
      → Dev: auto-syncs immediately
      → Prod: queues sync, requires manual approval in ArgoCD UI
```

A bad deployment is therefore, in the target state, always traceable to one Git commit in **this** repo (`petclinic-platform`) that changed one or more `helm-values/{service}.yaml` files' `image.tag`. Rolling back means getting that file back to the last-known-good tag, by whichever mechanism below fits the situation.

## Procedure: GitOps Rollback (Git Revert)

**When:** A bad image tag was deployed (service is unhealthy, erroring, or behaving incorrectly after a recent `update-image-tags.yml` commit) and ArgoCD (E-17) is deployed and auto-syncing.
**Who:** Anyone with push access to `petclinic-platform` (dev) — a repo maintainer for prod, since the revert still needs manual ArgoCD sync approval there.
**Time:** ~2-5 minutes (dev, auto-sync) / until the next manual approval window (prod).

**Steps:**
1. Find the bad commit: `git log --oneline -- helm-values/{service}.yaml` — look for the `ci: update image tags to {sha} (...)` commit that introduced the regression.
2. Revert it: `git revert --no-edit {bad-commit-sha}`
3. Push: `git push`
4. Dev: ArgoCD's `Application` for `{service}-dev` auto-syncs within its poll interval (default 3 min) or immediately if you trigger a manual refresh: `argocd app sync {service}-dev`
5. Prod: the revert queues in ArgoCD as OutOfSync; approve it explicitly: `argocd app sync {service}-prod` (or via the ArgoCD UI's Sync button)

**Verify:**
- `argocd app get {service}-{env}` shows `Synced` and `Healthy`
- `kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}` shows the expected (reverted) image tag: `kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service} -o jsonpath='{.items[0].spec.containers[0].image}'`
- Service-specific health check passes (e.g. `curl` the service's `/actuator/health` via port-forward, or through the ALB for api-gateway)

**Rollback (of this rollback):** if the revert itself was wrong (e.g. the "bad" image was actually fine and something else was the real cause), `git revert` the revert commit, or `git reset`/cherry-pick forward to the newer tag again — same mechanism, opposite direction.

## Procedure: ArgoCD Rollback (UI/CLI)

**When:** You need to roll back faster than a Git revert + sync cycle allows, or the bad commit is hard to identify quickly but you know a specific prior sync was good.
**Who:** Anyone with ArgoCD access (`kubectl port-forward svc/argocd-server -n argocd 8443:443`, per `docs/technical-spec.md#argocd-installation`).
**Time:** ~1-2 minutes.

**Steps:**
1. Find the last-known-good revision: `argocd app history {service}-{env}`
2. Roll back to it: `argocd app rollback {service}-{env} {revision-id}`
3. **Important:** this rolls back the live Kubernetes state, but NOT the Git repo — `helm-values/{service}.yaml` on `main` still has the bad tag. ArgoCD's self-heal (enabled in dev) will detect the drift and re-sync the bad tag right back in, undoing your rollback within its poll interval. Follow this CLI rollback with a [Git revert](#procedure-gitops-rollback-git-revert) to make the fix durable, or temporarily disable self-heal first: `argocd app set {service}-{env} --self-heal=false` (re-enable once the Git revert lands) — **verify this exact flag/command against the installed ArgoCD CLI version once E-17 exists**, this is unverified against a real ArgoCD install as of this writing.
4. Prod has no self-heal, so an ArgoCD CLI rollback there is stable until the next manual sync is approved — but still follow up with a Git revert so the repo's history matches what's actually running.

**Verify:** same as the GitOps procedure above — check `argocd app get` and the running pod's image tag.

**Rollback:** `argocd app rollback {service}-{env} {previous-revision-id}` back to where you started, or let a Git revert supersede it per step 3.

## Procedure: Helm Rollback (Current Interim Mechanism)

**When:** Right now, before E-17 (ArgoCD) exists — this is the actionable rollback path for this repo today, since deployments happen via direct `helm upgrade --install` (`docs/helm-guide.md`).
**Who:** Anyone with `kubectl`/`helm` access to the target cluster.
**Time:** ~1-2 minutes.

**Steps:**
1. Check release history: `helm history {service} -n petclinic-{env}`
2. Roll back to the last-known-good revision: `helm rollback {service} {revision-number} -n petclinic-{env}`
   - Alternatively, re-run the documented install command from `docs/helm-guide.md` with the previous good tag: `helm upgrade --install {service} helm/petclinic-service/ -n petclinic-{env} -f helm-values/{service}.yaml -f helm-values/{env}.yaml --set image.tag={previous-good-sha}`
3. If the bad tag was also committed to `helm-values/{service}.yaml` on `main` (e.g. by `update-image-tags.yml`), also revert that commit (see [GitOps Rollback](#procedure-gitops-rollback-git-revert) steps 1-3) so the repo stays the source of truth and a future `helm upgrade` from `main` doesn't reintroduce the bad tag.

**Verify:**
- `helm status {service} -n petclinic-{env}` shows `STATUS: deployed`
- `kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}` — pods `Running`/`Ready` with the expected image tag
- Re-run the relevant health check (actuator endpoint, or an end-to-end request through api-gateway)

**Rollback:** `helm rollback {service} {the-revision-you-just-rolled-back-from} -n petclinic-{env}` to undo the undo, or `helm history` to pick any other revision.

## Procedure: Emergency kubectl rollout undo

**When:** ArgoCD and Helm are both unavailable, unresponsive, or you need the absolute fastest path to stop active damage (e.g. a crash-looping bad image taking down a dependent service). This bypasses GitOps entirely — treat it as a stop-the-bleeding measure, not a fix. **Always follow up with a Git revert ([GitOps Rollback](#procedure-gitops-rollback-git-revert)) once things are stable**, or ArgoCD's self-heal (dev) / the next Helm deploy will overwrite this with the bad tag again.
**Who:** Anyone with `kubectl` access to the target cluster.
**Time:** Seconds.

**Steps:**
1. Check rollout history: `kubectl rollout history deployment/{service} -n petclinic-{env}`
2. Undo to the previous revision: `kubectl rollout undo deployment/{service} -n petclinic-{env}`
   - Or to a specific revision: `kubectl rollout undo deployment/{service} -n petclinic-{env} --to-revision={N}`
3. Watch the rollout: `kubectl rollout status deployment/{service} -n petclinic-{env}`

**Verify:**
- `kubectl rollout status deployment/{service} -n petclinic-{env}` reports success
- `kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}` — pods `Running`/`Ready`
- `Running`/`Ready` only confirms the probes pass, not that the service is actually correct — follow up with the same health/functional check you'd use for the other procedures (actuator endpoint, or an end-to-end request through api-gateway) before considering the incident resolved

**Rollback:** `kubectl rollout undo deployment/{service} -n petclinic-{env}` again steps back one more revision; `--to-revision={N}` targets any specific one in `kubectl rollout history`.

## Choosing Which Procedure to Use

| Situation | Procedure |
|-----------|-----------|
| ArgoCD exists, you have a few minutes, want the repo and cluster to match | [GitOps Rollback](#procedure-gitops-rollback-git-revert) |
| ArgoCD exists, need it fixed *now*, will clean up Git after | [ArgoCD Rollback](#procedure-argocd-rollback-uicli) |
| ArgoCD doesn't exist yet (current state of this repo) | [Helm Rollback](#procedure-helm-rollback-current-interim-mechanism) |
| Everything above is unavailable/too slow, actively bleeding | [Emergency kubectl rollout undo](#procedure-emergency-kubectl-rollout-undo) |

In every case except the pure emergency fallback, finish by making sure `helm-values/{service}.yaml` on `main` reflects the tag that's actually running — that file is this platform's source of truth, and letting it drift from reality is how the same bad tag comes back on the next sync or deploy.
