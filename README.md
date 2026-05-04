# homelab-review-apps

Reusable GitHub Actions workflows for ephemeral preview environments and
Swarm-based prod deploys, designed for self-hosted homelab infrastructure.
Framework-agnostic: each consuming project provides its own `bin/preview-up`,
`bin/preview-down`, and `bin/deploy-prod` scripts plus its own compose files;
the workflows here orchestrate the GitHub side (PR labels, sticky comments,
concurrency, ntfy notifications, rollback paths).

This is private infrastructure, not a public action — it assumes:

- A self-hosted GitHub Actions runner labeled `self-hosted, macmini, orbstack`
  on the Mac Mini that hosts the preview Compose stacks.
- A self-hosted runner labeled `self-hosted, archimedes, swarm` on the Swarm
  manager node for prod deploys.
- A Traefik instance on the Mac Mini proxying the `edge` Docker network with
  a wildcard mkcert cert covering the project's preview hostnames.
- Tailscale split-DNS routing `*.<domain-suffix>` at the Mini's tailnet IP
  via a `dnsmasq` instance on the `edge` network.
- A self-hosted ntfy at `https://ntfy.apetre.sc` for notifications.

## Workflows

### `preview-up.yml`
Brings up an ephemeral preview env for a labeled PR.

```yaml
# .github/workflows/preview-up.yml in the consuming repo
on:
  pull_request:
    types: [labeled, synchronize, reopened]

jobs:
  preview:
    if: contains(github.event.pull_request.labels.*.name, 'preview')
    uses: apetresc/homelab-review-apps/.github/workflows/preview-up.yml@v1
    with:
      project: rps
      domain_suffix: rps.eastbrid.ge
      ntfy_topic: rps-deploys
    secrets: inherit
```

### `preview-down.yml`
Tears down the preview when the PR closes or the `preview` label is removed.

```yaml
on:
  pull_request:
    types: [closed, unlabeled]

jobs:
  preview-down:
    uses: apetresc/homelab-review-apps/.github/workflows/preview-down.yml@v1
    with:
      project: rps
      ntfy_topic: rps-deploys
    secrets: inherit
```

### `deploy-prod.yml`
Builds + pushes images to GHCR on master push, then deploys via the project's
`bin/deploy-prod` on the Swarm manager. Supports rollback via `workflow_dispatch`
with a `tag` input.

```yaml
on:
  push:
    branches: [master]
  workflow_dispatch:
    inputs:
      tag:
        description: Image tag to deploy (defaults to commit SHA, set for rollback)
        required: false

jobs:
  deploy:
    uses: apetresc/homelab-review-apps/.github/workflows/deploy-prod.yml@v1
    with:
      project: rps
      images: |
        [
          {"name": "eastbridge-rps-api", "dockerfile": "docker/Dockerfile.app", "target": "api"},
          {"name": "eastbridge-rps-worker", "dockerfile": "docker/Dockerfile.app", "target": "worker"},
          {"name": "eastbridge-rps-web", "dockerfile": "docker/Dockerfile.frontend", "target": "production"}
        ]
      health_url: https://rps.eastbrid.ge/api/healthz
      ntfy_topic: rps-deploys
      tag: ${{ inputs.tag || '' }}
    secrets: inherit
```

## Per-project script contract

The reusable workflows shell out to scripts in the consuming repo so the
orchestration stays framework-agnostic. The scripts must accept these args:

| Script | Signature |
|---|---|
| `bin/preview-up` | `<slug> --branch <ref> [--ntfy-topic <topic>]` |
| `bin/preview-down` | `<slug> [--ntfy-topic <topic>]` |
| `bin/deploy-prod` | `<image-tag>` |

See the eastbridge-rps repo for reference implementations.

## Versioning

Tag releases as `v1`, `v1.1`, etc. Callers pin to `@v1` (auto-pulls minor
updates) or to a specific tag. Breaking changes bump the major.

## Visibility

This repo is public. Public reusable workflows can be called by any repo
on GitHub.com, regardless of owner — which is the whole point here, since
consumers span personal-account repos (`apetresc/...`) and organization
repos (`eastbridge-academy/...`) and GitHub's private-repo sharing model
doesn't span owners on personal accounts.

Nothing in these workflows is secret: no tokens, no keys, no proprietary
logic. Secrets (GHCR auth, etc.) are inherited from the *caller's* repo
at runtime via `secrets: inherit` and never appear here. The reusable
workflow runs under the caller repo's `GITHUB_TOKEN`.
