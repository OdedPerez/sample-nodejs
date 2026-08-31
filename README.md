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

See [`helm/sample-nodejs/README.md`](helm/sample-nodejs/README.md) for the Helm chart (Deployment, Service, Ingress, ConfigMap/Secret, HPA/PDB, security hardening) and how to deploy it, including a local minikube walkthrough.

## CI/CD pipeline

Two GitHub Actions workflows, split by trigger:

- **[`pr-checks.yml`](.github/workflows/pr-checks.yml)** (on pull requests to `main`): `lint` → `sast` (Semgrep, `--config auto`, gated on `ERROR` severity only — same "block on the serious stuff, not the noise" philosophy as the Trivy gate; WARNING/INFO findings still print in the log but don't fail the job) → `build-scan-push` (builds the image, runs a Trivy scan gated on HIGH/CRITICAL severity, and only pushes to GHCR if the scan passes) → `deploy-dev` (bumps this repo's `helm/sample-nodejs/values-dev.yaml` image tag and commits back to the PR branch, so the reviewer sees the dev-deploy diff inline in the PR). Nothing is version-tagged or touches `main` from a PR.
- **[`release.yml`](.github/workflows/release.yml)** (on push to `main`): `verify` (lint) → `sast` (same Semgrep gate as `pr-checks.yml` — a **separate, self-contained run**, not trusting that the PR path's `sast` job already covered this code, since this repo has no branch protection requiring PRs and direct pushes to `main` are possible) → `version` (computes the next SemVer tag from Conventional Commits since the last tag, e.g. `fix:` → patch, `feat:` → minor, `!`/`BREAKING CHANGE` → major) → `build-scan-push` (same Trivy gate; builds for `linux/arm64` via QEMU emulation, matching the local minikube deployment target, then pushes `:vX.Y.Z` and `:latest` to GHCR) → `deploy-staging` → `deploy-prod` (gated behind a `production` GitHub Environment's manual approval). Unlike `deploy-dev`, these two **push to the separate [`sample-nodejs-gitops`](https://github.com/OdedPerez/sample-nodejs-gitops) repo** (via a fine-grained PAT, secret `GITOPS_REPO_TOKEN`) rather than committing back into this repo — see the GitOps section below for why.

**Registry**: GHCR (`ghcr.io/odedperez/sample-nodejs`, public), authenticated via the workflow's own `GITHUB_TOKEN` for pushes — no credential needed to pull.

**Branching**: GitHub Flow — a single `main`, short-lived feature branches, PR-gated merges. No long-lived per-environment branches.

**SAST findings, current state** (Semgrep `--config auto` against this repo): 22 WARNING-severity findings (GitHub Actions steps using mutable tags like `@v4` instead of a pinned commit SHA — a real supply-chain concern, but a different category from app-code SAST, left visible but non-blocking) and 1 INFO-severity finding (missing CSRF middleware in `app.js` — a true pattern match, but not practically exploitable here: the app has zero POST/PUT/DELETE routes or session/cookie state for CSRF to target). Zero ERROR-severity findings, so the gate currently passes.

**Deliberately deferred** (tracked, not forgotten):
- **Automated tests** — `package.json`'s `test` script is still the original placeholder that always fails; no test job exists yet. Smoke tests (`node:test`/Jest + `supertest` against `/my-app`, `/about`, `/ready`, `/live`, `/metrics`) are planned for a later stage rather than added hastily now.

## GitOps & ArgoCD

Staging and production are managed by [ArgoCD](https://argo-cd.readthedocs.io/), watching **[`sample-nodejs-gitops`](https://github.com/OdedPerez/sample-nodejs-gitops)** — a separate repo holding per-environment values and the ArgoCD `Application` manifests, while the Helm chart itself stays here (coupled to the app code and Dockerfile it packages).

Each `Application` is a **multi-source** ArgoCD Application: one source pulls the chart from this repo, the other pulls the matching values file from `sample-nodejs-gitops`, merged via Helm's `valueFiles`. `release.yml`'s `deploy-staging`/`deploy-prod` jobs are the only thing that ever writes to `sample-nodejs-gitops` — bumping `image.tag` to the version just built, scanned, and pushed. ArgoCD reconciles the cluster automatically from there (`syncPolicy.automated` with `prune`/`selfHeal`) — the git commit *is* the deployment, no `kubectl`/`helm` call from CI.

See `sample-nodejs-gitops`'s README for the full reasoning on the repo split.
