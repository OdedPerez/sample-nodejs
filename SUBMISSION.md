# Submission

## Repositories

- **App repo**: https://github.com/OdedPerez/sample-nodejs - source code, Dockerfile, CI/CD pipelines
- **GitOps repo**: https://github.com/OdedPerez/sample-nodejs-gitops - Helm chart, ArgoCD `Application`/`AppProject` manifests, per-environment Helm values, its own chart validation CI

Both repos are public, the container image registry is private. Evidence screenshots are provided separately.

---

## Helm chart

Lives at [`helm/sample-nodejs/`](https://github.com/OdedPerez/sample-nodejs-gitops/tree/main/helm/sample-nodejs) in the GitOps repo, alongside the per-environment values it's deployed with:

```
helm/
└── sample-nodejs/
    ├── Chart.yaml              # chart + app version
    ├── values.yaml             # all defaults (HA features ON)
    ├── values-minikube.yaml    # single-node overlay (HA features OFF)
    ├── .helmignore
    └── templates/
        ├── _helpers.tpl        # shared naming/labels
        ├── deployment.yaml     # probes, resources, security, env-from cm/secret
        ├── service.yaml
        ├── ingress.yaml
        ├── configmap.yaml
        ├── secret.yaml
        ├── serviceaccount.yaml
        ├── hpa.yaml
        ├── pdb.yaml
        ├── networkpolicy.yaml   # opt-in
        ├── servicemonitor.yaml  # opt-in
        └── NOTES.txt
```

**Deployment, not StatefulSet**: the app is stateless, replicas are interchangeable, hold no per-pod data, need no stable network identity or ordered startup. A Deployment gives fast horizontal scaling and zero downtime rolling updates. A StatefulSet earns its complexity for workloads needing stable identities and per-replica persistent volumes, neither of which applies here.

**What's covered, and why:**

- **Readiness / liveness / startup probes** - all three wired to the app's real `/live` and `/ready` endpoints, not placeholder paths. Liveness restarts a genuinely wedged process; readiness keeps traffic away from a pod that isn't ready yet; the startup probe gives the container time to come up before liveness would otherwise kill it prematurely.
- **Service + Ingress** - a `ClusterIP` Service gives stable internal routing regardless of pod churn; an `nginx`-class Ingress maps a real hostname to it. This is what makes the app reachable in a browser at all.
- **CPU/memory requests *and* limits** - both set. Requests drive scheduling and feed the HPA's utilization math, limits cap worst case usage so one pod can't starve its node.
- **ConfigMap + Secret** - both populated from `values.yaml` and injected via `envFrom`, with a `checksum/*` pod-template annotation that forces a rollout whenever their content changes. `Secret` supports `existingSecret` so a real deployment can defer to Sealed Secrets / External Secrets / Vault instead of committing real credentials to git.
- **HPA** - CPU/memory-based autoscaling between a min/max replica range, so replica count responds to real load instead of being statically fixed.
- **PodDisruptionBudget** - `minAvailable` set, protecting availability during *voluntary* disruptions (node drains, cluster upgrades).
- **Topology spread constraints** - pods are spread across nodes where possible, so a single node failure doesn't take out every replica at once.
- **A dedicated, non-root ServiceAccount** - its own identity per app rather than the namespace default, with `automountServiceAccountToken: false`.
- **Hardened container security context** - non-root, read-only root filesystem, all Linux capabilities dropped, seccomp `RuntimeDefault`, with a small `emptyDir` at `/tmp` since the root filesystem is read-only. Defense in depth: limits the blast radius if the app were ever compromised.
- **Opt-in NetworkPolicy** - disabled by default (this project's actual traffic pattern doesn't require it).
- **Opt-in Prometheus `ServiceMonitor` + Grafana dashboard** - enabled for production. See Observability, below, for what it actually shows.

**Deploying it**:

Multi-node cluster (defaults, HA on):
```bash
helm upgrade --install sample-nodejs helm/sample-nodejs \
  -n sample-nodejs --create-namespace
```

Single-node minikube (HA features off - see the overlay). The image builds from `sample-nodejs`'s Dockerfile; the `helm` commands run from `sample-nodejs-gitops`'s root:
```bash
minikube addons enable ingress
eval $(minikube docker-env) && docker build -t sample-nodejs:local .   # from sample-nodejs
helm upgrade --install sample-nodejs helm/sample-nodejs \
  -f helm/sample-nodejs/values-minikube.yaml \
  -n sample-nodejs --create-namespace                                  # from sample-nodejs-gitops
```

Staging and production aren't deployed either of these ways - see GitOps & ArgoCD, below.

---

## CI/CD pipeline (GitHub Actions)

Two workflows, split by trigger. Jobs are grouped by concern rather than creation order. A pipeline meta-check first, then code checks, then security checks, then the expensive build/deploy work - with everything in the first three groups gating the last. Chart validation isn't part of either workflow: the chart lives in `sample-nodejs-gitops`, which has its own `chart-validate.yml` CI (see GitOps & ArgoCD, below).

- **`pr-checks.yml`** (pull requests to `main`): `actionlint` (lints the workflow files themselves) → `lint` (ESLint) / `dockerfile-lint` (hadolint) → `sast` (Semgrep) / `dependency-audit` (`npm audit`) / `secret-scan` (gitleaks, full git history) → `build-and-scan` (builds the image locally, Trivy scan gated on HIGH/CRITICAL). Nothing is pushed or deployed from a PR - this proves the image builds cleanly and passes the vulnerability gate before merge, nothing more.
- **`release.yml`** (push to `main`): the same six checks re-run **independently** (not trusting that `pr-checks.yml` already ran them, since this repo has no branch protection requiring PRs and a direct push to `main` is possible) → `version` (SemVer tag from Conventional Commits) → `build-scan-push` (same Trivy gate; builds for `linux/arm64` via QEMU emulation matching the local minikube deployment target, then pushes `:vX.Y.Z` and `:latest` to GHCR) → `deploy-staging` → `deploy-prod` (gated behind a `production` GitHub Environment's manual approval). These last two push to `sample-nodejs-gitops` (via a fine-grained, repo-scoped PAT, secret `GITOPS_REPO_TOKEN`) rather than committing back into this repo - see GitOps & ArgoCD, below.

**Version bumping / git workflow**: GitHub Flow - a single `main`, short-lived feature branches, PR-gated merges. Version bumps are automatic: SemVer tags computed from Conventional Commits (`fix:` → patch, `feat:` → minor, `!`/`BREAKING CHANGE` → major) on every merge to `main`, via `mathieudutour/github-tag-action`.

**SAST**: [Semgrep](https://semgrep.dev/) (`--config auto`), run in **both** workflows independently, not just the PR path. Gated on `ERROR` severity only, mirroring the Trivy gate's "block on the serious stuff, not the noise" philosophy.

**Docker image vulnerability scanning**: [Trivy](https://trivy.dev/), gated on `HIGH,CRITICAL` severity - nothing is pushed to the registry unless the scan passes.

**Build & Dockerization**: multi-stage Dockerfile (Alpine base, non-root user), built for `linux/arm64` via QEMU emulation to match the actual deployment target (local minikube on Apple Silicon).

**Registry**: GitHub Container Registry (`ghcr.io/odedperez/sample-nodejs`), **private**. `release.yml` pushes using the workflow's own `GITHUB_TOKEN`. Staging and production each pull via a dedicated `ghcr-pull-secret` - a `kubernetes.io/dockerconfigjson` Secret created once per namespace (`kubectl create secret docker-registry`, holding a classic PAT scoped to `read:packages` and wired into the Deployment via the chart's `imagePullSecrets` field, set per-environment in `sample-nodejs-gitops`.

**Deployment stage**: see GitOps section below - CI's role stops at pushing a versioned image and updating the environment's `image.tag` in the GitOps repo; ArgoCD does the actual cluster deployment.

---

## GitOps & ArgoCD

**Chose**: a **separate GitOps repository** (`sample-nodejs-gitops`), monitored by ArgoCD - over ArgoCD pulling manifests directly from the app repo. That repo holds the Helm chart itself, per-environment values, and the ArgoCD `Application`/`AppProject` manifests together, so it fully owns everything ArgoCD needs to deploy the app.

**Why**: separating deployment concerns (chart, values, `Application`/`AppProject` manifests) from application concerns (source code, Dockerfile, CI) keeps each repo's change cadence and CI independent - a values bump doesn't touch the app repo's pipeline, and an app code change doesn't require touching deployment manifests. It also means CI never writes generated deployment-state commits back into the app repo's own history. One direct benefit of keeping the chart alongside its values (rather than split across two repos): each `Application` is a **single-source** ArgoCD Application (`path: helm/sample-nodejs`, `helm.valueFiles: ['../../<env>/values.yaml']`) instead of the more complex multi-source split (`sources:` + `ref: values`) a cross-repo chart/values split would otherwise need. Chart correctness (lint, render against real staging/production values) is this repo's own concern, checked by its own `chart-validate.yml` CI on every PR and push.

**How deployment state gets updated**: `release.yml`'s `deploy-staging`/`deploy-prod` jobs are the only thing that ever writes to the GitOps repo (via a fine-grained, repo-scoped PAT), bumping `image.tag` to the version it just built, scanned, and pushed. ArgoCD reconciles the cluster automatically from there (`syncPolicy.automated` with `prune`/`selfHeal`) - **the git commit is the deployment**, no `kubectl`/`helm` call from CI.

**Namespace-per-environment isolation**: `sample-nodejs-staging` and `sample-nodejs-prod` are each their own dedicated namespace.

**AppProject-based RBAC isolation**: each environment's `Application` is scoped to its own `AppProject`, restricting it to only its own namespace and only the GitOps repo as a source.

**Cluster**: local minikube.

---

## Observability: Prometheus & Grafana

`kube-prometheus-stack` (Prometheus Operator, Prometheus, Alertmanager, Grafana) installed declaratively via ArgoCD (`sample-nodejs-gitops/argocd/application-monitoring.yaml`), one manifest, applied once to register, ArgoCD owns it from there.

The chart's opt-in `ServiceMonitor` and a Grafana dashboard are both enabled for production. The dashboard has five panels against the app's actual exposed metrics: `/my-app` request rate, CPU usage, resident memory, event loop lag, and heap usage.

---

## Deployment evidence

Screenshots (provided separately).
