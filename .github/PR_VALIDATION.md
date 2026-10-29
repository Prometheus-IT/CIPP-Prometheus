# Prometheus pre-merge checks

`prometheus-pr-validation.yml` runs on every PR targeting `main`, including fork
PRs, and on merge-queue candidates. There are no path filters or draft exclusions.
The default checkout tests GitHub's proposed merge commit.

## Stable release build

The workflow calls the same `prometheus/pipeline.py resolve --force` and `prepare`
commands as the production publisher. It resolves the latest official stable CIPP
release once, checks out that exact upstream commit, applies the proposed overlay,
builds `build/Dockerfile.release` for linux/amd64 and runs the existing packaged
smoke checks. A recorded build-state never skips PR validation. The run summary
records the upstream SHA, application version and proposed merge SHA.

This is an application build and package test, not an authenticated live-tenant
integration test. Only the custom files selected by `prepare` enter the release,
just as in production.

## Security policy

- **Secrets:** Gitleaks v8.30.1 scans every commit in the PR's base-to-head range,
  including secrets added and later removed. Built-in detection rules are used;
  PR-provided Gitleaks configuration and inline allow comments cannot suppress
  findings. Output is fully redacted. Any finding or scanner error fails the job.
- **Dependencies:** the existing `Dependency Review` workflow now also runs in
  Prometheus. Its existing moderate-or-higher policy is retained. It reviews the
  proposed dependency changes, including lockfiles, using GitHub's dependency
  graph. API/graph errors fail the check; enable the dependency graph if GitHub
  reports it unavailable. No PR comment permission is required.
- **Final container:** Trivy scans OS and library dependencies in the actual
  prepared release image. HIGH/CRITICAL findings with an available fix block the
  check, including inherited upstream/base-image findings. All severities and
  unfixed findings remain in the JSON report, retained for 14 days. Missing,
  malformed or empty scan results fail closed. There is no vulnerability baseline
  or CVE suppression list. Fixes to upstream/base images may therefore be required
  before a PR can pass.

The jobs use read-only repository permissions, hosted disposable runners and
SHA-pinned actions. They do not receive production credentials, log in to a
registry, publish images, change build-state, deploy or access customer tenants.
They may read the production build cache but do not write to it.

## Required status checks

After these workflows have run, configure the `main` protection rule/ruleset to
require the following checks before merging:

1. `Stable release build and image security`
2. `PR secret scan`
3. `dependency-review` (the job in `Dependency Review`)

Workflow files alone do not enforce merge protection. Preserve other existing
required checks. The production publisher remains separate and unchanged.
