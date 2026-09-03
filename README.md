# DevOps Sample Node.js App

## Overview

A lightweight Node.js application. It features basic web endpoints, Prometheus metrics integration, and is designed for Kubernetes deployment and CI/CD pipeline demonstrations.

## Features

- Express.js web server
- Prometheus metrics integration
- Readiness and liveness probe endpoints
- Customizable port via environment variable

## Prerequisites

- Node.js (v22.1.0)

## Kubernetes deployment

The Helm chart (Deployment, Service, Ingress, ConfigMap/Secret, HPA/PDB, security hardening) lives in the separate [`sample-nodejs-gitops`](https://github.com/OdedPerez/sample-nodejs-gitops) repo, alongside the per-environment values and ArgoCD manifests — see [`helm/sample-nodejs/README.md`](https://github.com/OdedPerez/sample-nodejs-gitops/blob/main/helm/sample-nodejs/README.md) there for the chart itself and a local minikube walkthrough.

## CI/CD pipeline

Two GitHub Actions workflows, split by trigger:

Jobs are grouped by concern rather than listed in creation order: a pipeline meta-check first, then code checks, then security checks, then the expensive build/deploy work — everything in the first three groups gates the last. Chart validation isn't part of this repo's pipeline at all — the Helm chart lives in `sample-nodejs-gitops`, which has its own `chart-validate.yml` CI (see that repo's README).

- **[`pr-checks.yml`](.github/workflows/pr-checks.yml)** (on pull requests to `main`): `actionlint` (validates the workflow files themselves) → `lint` / `dockerfile-lint` (hadolint) → `sast` (Semgrep, `--config auto`, gated on `ERROR` severity only — same "block on the serious stuff, not the noise" philosophy as the Trivy gate; WARNING/INFO findings still print in the log but don't fail the job) / `dependency-audit` (`npm audit`, gated on high/critical only) / `secret-scan` (gitleaks, full git history) → `build-and-scan` (builds the image locally and runs a Trivy scan gated on HIGH/CRITICAL severity). Nothing is pushed or deployed from a PR — this proves the image builds cleanly and passes the vulnerability gate before merge, nothing more. Pushing a real, deployable image only happens in `release.yml`, after code has actually landed on `main`.
- **[`release.yml`](.github/workflows/release.yml)** (on push to `main`): same grouping — `actionlint` → `verify` (lint) / `dockerfile-lint` → `sast` / `dependency-audit` / `secret-scan` (all mirrored from `pr-checks.yml` — **separate, self-contained runs**, not trusting the PR path already covered this code, since this repo has no branch protection requiring PRs and direct pushes to `main` are possible) → `version` (computes the next SemVer tag from Conventional Commits since the last tag, e.g. `fix:` → patch, `feat:` → minor, `!`/`BREAKING CHANGE` → major) → `build-scan-push` (same Trivy gate; builds for `linux/arm64` via QEMU emulation, matching the local minikube deployment target, then pushes `:vX.Y.Z` and `:latest` to GHCR) → `deploy-staging` → `deploy-prod` (gated behind a `production` GitHub Environment's manual approval). These two jobs **push to the separate [`sample-nodejs-gitops`](https://github.com/OdedPerez/sample-nodejs-gitops) repo** (via a fine-grained PAT, secret `GITOPS_REPO_TOKEN`) rather than committing back into this repo — see the GitOps section below for why.

**Extra checks, current real findings** (all pass today, gated on real thresholds rather than assumed):
- `hadolint` (Dockerfile): 2 `info`-severity findings (consecutive `RUN` instructions, non-numeric `USER`) — gate only fails on `error`.
- `gitleaks` (secret scanning, full git history): 0 findings.
- `npm audit`: 3 `moderate`-severity findings (transitive `qs`/`body-parser` DoS advisories, fixable via `npm audit fix`) — gate only fails on `high`/`critical`.
- `actionlint`: 0 findings.

**Registry**: GHCR (`ghcr.io/odedperez/sample-nodejs`), **private**. `release.yml` pushes using the workflow's own `GITHUB_TOKEN`; staging and production pull using a dedicated `ghcr-pull-secret` (a `kubernetes.io/dockerconfigjson` Secret, created once per namespace, holding a classic PAT scoped to `read:packages` — GHCR doesn't yet support fine-grained PATs for registry auth) wired in via each environment's `imagePullSecrets` in `sample-nodejs-gitops`.

**Branching**: GitHub Flow — a single `main`, short-lived feature branches, PR-gated merges. No long-lived per-environment branches.

**SAST findings, current state** (Semgrep `--config auto` against this repo): 22 WARNING-severity findings (GitHub Actions steps using mutable tags like `@v4` instead of a pinned commit SHA — a real supply-chain concern, but a different category from app-code SAST, left visible but non-blocking) and 1 INFO-severity finding (missing CSRF middleware in `app.js` — a true pattern match, but not practically exploitable here: the app has zero POST/PUT/DELETE routes or session/cookie state for CSRF to target). Zero ERROR-severity findings, so the gate currently passes.

**Deliberately deferred** (tracked, not forgotten):
- **Automated tests** — `package.json`'s `test` script is still the original placeholder that always fails; no test job exists yet. Smoke tests (`node:test`/Jest + `supertest` against `/my-app`, `/about`, `/ready`, `/live`, `/metrics`) are planned for a later stage rather than added hastily now.

## GitOps & ArgoCD

Staging and production are managed by [ArgoCD](https://argo-cd.readthedocs.io/), watching **[`sample-nodejs-gitops`](https://github.com/OdedPerez/sample-nodejs-gitops)** — a separate repo holding the Helm chart, per-environment values, and the ArgoCD `Application` manifests together.

Each `Application` is a single-source ArgoCD Application: chart and values both come from `sample-nodejs-gitops`. `release.yml`'s `deploy-staging`/`deploy-prod` jobs are the only thing that ever writes to that repo — bumping `image.tag` to the version just built, scanned, and pushed. ArgoCD reconciles the cluster automatically from there (`syncPolicy.automated` with `prune`/`selfHeal`) — the git commit *is* the deployment, no `kubectl`/`helm` call from CI. Each environment is isolated at the ArgoCD level via its own `AppProject` (own namespace, own source repo).

See `sample-nodejs-gitops`'s README for the full reasoning on the repo split and why the chart lives there.
