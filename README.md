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

## CI/CD pipeline

Two GitHub Actions workflows: [`pr-checks.yml`](.github/workflows/pr-checks.yml) (on pull requests - lint, SAST, dependency audit, secret scan, then a local build + Trivy scan with nothing pushed) and [`release.yml`](.github/workflows/release.yml) (on push to `main` - the same checks, plus SemVer versioning, build/scan/push to a private registry, and deployment to staging then production behind a manual approval gate). Chart validation lives in `sample-nodejs-gitops`'s own CI, not here.

For the full job-by-job breakdown, current findings, and the reasoning behind the pipeline structure, see [`SUBMISSION.md`](SUBMISSION.md#cicd-pipeline-github-actions).

## Kubernetes deployment

The Helm chart (Deployment, Service, Ingress, ConfigMap/Secret, HPA/PDB, security hardening) lives in the separate [`sample-nodejs-gitops`](https://github.com/OdedPerez/sample-nodejs-gitops) repo, alongside the per-environment values and ArgoCD manifests - see [`helm/sample-nodejs/README.md`](https://github.com/OdedPerez/sample-nodejs-gitops/blob/main/helm/sample-nodejs/README.md) there for the chart itself and a local minikube walkthrough.

## GitOps & ArgoCD

Staging and production are managed by [ArgoCD](https://argo-cd.readthedocs.io/), watching the separate [`sample-nodejs-gitops`](https://github.com/OdedPerez/sample-nodejs-gitops) repo, which holds the Helm chart, per-environment values, and the ArgoCD `Application`/`AppProject` manifests together.

See [`SUBMISSION.md`](SUBMISSION.md#gitops--argocd) for the full reasoning behind the repo split.
