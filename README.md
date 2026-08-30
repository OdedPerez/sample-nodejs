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

- **[`pr-checks.yml`](.github/workflows/pr-checks.yml)** (on pull requests to `main`): `lint` → `sast` (placeholder, see below) → `build-scan-push` (builds the image, runs a Trivy scan gated on HIGH/CRITICAL severity, and only pushes to GHCR if the scan passes) → `deploy-dev` (bumps `helm/sample-nodejs/values-dev.yaml`'s image tag and commits back to the PR branch). Nothing is version-tagged or touches `main` from a PR.
- **[`release.yml`](.github/workflows/release.yml)** (on push to `main`): `verify` (lint) → `version` (computes the next SemVer tag from Conventional Commits since the last tag, e.g. `fix:` → patch, `feat:` → minor, `!`/`BREAKING CHANGE` → major) → `build-scan-push` (same Trivy gate, pushes `:vX.Y.Z` and `:latest` to GHCR) → `deploy-staging` (bumps `values-staging.yaml` + `Chart.yaml` `appVersion`, commits to `main`) → `deploy-prod` (same, for `values-prod.yaml`, gated behind a `production` GitHub Environment's manual approval — **requires that Environment to be configured with a required reviewer in repo settings** for the gate to actually pause the run).

**Registry**: GHCR (`ghcr.io/odedperez/sample-nodejs`), authenticated via the workflow's own `GITHUB_TOKEN` — no extra secrets to provision.

**Branching**: GitHub Flow — a single `main`, short-lived feature branches, PR-gated merges. No long-lived per-environment branches; instead each environment (`dev`/`staging`/`prod`) is its own Helm values overlay (`helm/sample-nodejs/values-{dev,staging,prod}.yaml`), and the pipeline's only "deploy" action is updating that environment's `image.tag`. This is deliberate: once ArgoCD is wired up (a later phase of this project), it watches those values files and reconciles the cluster — the git commit *is* the deployment, not a `kubectl`/`helm` call from CI.

**Known open item**: a local Trivy scan against the built image currently finds HIGH/CRITICAL findings (mostly from the `npm` CLI bundled inside the `node:22-alpine` base image itself, not the app's own dependencies) that would fail this gate as configured today. Not yet resolved — see the pipeline's TODOs before relying on `pr-checks.yml`/`release.yml` staying green.

**Deliberately deferred** (tracked, not forgotten):
- **SAST** — `pr-checks.yml` has a stubbed `sast` job (already wired into the job dependency graph) with a `TODO` marking where Semgrep or CodeQL should go, gated to fail on critical findings.
- **Automated tests** — `package.json`'s `test` script is still the original placeholder that always fails; no test job exists yet. Smoke tests (`node:test`/Jest + `supertest` against `/my-app`, `/about`, `/ready`, `/live`, `/metrics`) are planned for a later stage rather than added hastily now.
