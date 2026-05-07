# Self-hosted GitHub Actions runners

Bootstrap scripts and configuration for the self-hosted runners that
the workflows in this repo dispatch to.

The reusable workflows here are framework- and org-agnostic; they target
runners by **label**, not by name or owner. So a single set of physical
runners can serve any number of GitHub orgs / users — you just register
one runner per (owner, machine, capability-set) combination, with the
labels the workflows ask for.

## Why self-hosted

GitHub-hosted runners can't reach a homelab Swarm or a Mac Mini's
OrbStack daemon, both of which the workflows in this repo orchestrate.
Specifically:

- **`preview-up.yml` / `preview-down.yml`** run `docker compose` against
  a host-local Docker daemon. They need a runner co-located with that
  daemon — typically a Mac Mini or Linux box where development
  environments live.
- **`deploy-prod.yml`** runs `docker stack deploy` against a Swarm
  manager. Only a runner *on the manager node* can do that.

## Runners in this scheme

| Script | Host kind | Service | Default labels | Used by |
|---|---|---|---|---|
| `install-macmini.sh` | macOS (arm64) | launchd LaunchAgent | `self-hosted, macmini, orbstack` | preview-up / preview-down |
| `install-swarm-manager.sh` | Linux (x86_64 / arm64) | systemd | `self-hosted, swarm` | deploy-prod |

Each script:

- Pins the runner version (`RUNNER_VERSION` at the top, default 2.334.0).
- Disables runner self-update (`--disableupdate`) so binary changes
  happen on your timeline, not GitHub's.
- Uses `--replace` so re-running with a fresh token replaces an existing
  registration without leftover state — same script handles first
  install and re-registration.
- Registers at **org/user level** (`--url https://github.com/${ORG}`,
  no repo suffix), so every repo under that owner can dispatch to the
  runner.

The runner binary itself is **not** committed — it's downloaded fresh
during install to `~/actions-runner-${ORG}/`, outside this repo.

## First-time install

Get a registration token from
`https://github.com/organizations/<your-org>/settings/actions/runners/new`
(or the user-account equivalent for personal accounts).

⚠️ **Don't confuse the registration token with the SHA-256 hash.** That
page shows two distinct values — the SHA hash near the top (download
verification, 64 hex chars) and the `--token` argument near the bottom
(~29 chars, starts with `A`). The scripts want the latter. Pasting the
former returns HTTP 404 from GitHub's runner-registration endpoint with
an unhelpful error message; the scripts now sanity-check for this.

### macOS (Mac Mini, OrbStack)

```sh
cd <path-to-this-repo>/runners
./install-macmini.sh                    # prompts for token (input hidden)
# or
RUNNER_TOKEN=<token> ./install-macmini.sh
# Override the default org:
ORG=<other-org> ./install-macmini.sh
```

`install-macmini.sh` copies `runner.env` into the runner's working dir
as `.env` so jobs find Homebrew-installed tools (`docker`, `git`, `gh`,
`uv`, `jq`, etc.) and OrbStack's non-default Docker socket
(`unix:///Users/apetresc/.orbstack/run/docker.sock`). Without that, jobs
fail with cryptic `command not found` errors because launchd hands over
a minimal PATH.

The launchd LaunchAgent (per-user, not LaunchDaemon) starts on user
login. Mac Minis that stay logged in get effectively-auto-start
behavior; LaunchDaemons would also handle reboot-without-login but at
the cost of running the runner as root, which we don't want.

### Linux (Swarm manager)

```sh
cd <path-to-this-repo>/runners
./install-swarm-manager.sh              # prompts for token
# or
RUNNER_TOKEN=<token> ./install-swarm-manager.sh
# Override defaults:
ORG=<other-org> RUNNER_NAME=<custom-name> ./install-swarm-manager.sh
```

The runner needs to:

- Run as a non-root user.
- Be in the `docker` group on the manager node so `docker stack deploy`
  works against the local socket without sudo.
- Have GHCR pull credentials provisioned beforehand so
  `--with-registry-auth` can propagate them to all Swarm nodes:
  `docker login ghcr.io -u <user> -p <PAT-with-read:packages>`.

systemd unit installed: `actions.runner.${ORG}.${RUNNER_NAME}.service`.
Tail logs with
`journalctl -u actions.runner.${ORG}.${RUNNER_NAME}.service -f`.

## Updating the runner

Self-update is off, so:

1. Bump `RUNNER_VERSION=` in the relevant install script.
2. Get a fresh registration token (any owner's URL — same scope rules).
3. Re-run the script. It downloads the new version, stops the service,
   re-registers (idempotent), and restarts.

Latest releases: <https://github.com/actions/runner/releases>

## Uninstall

```sh
./uninstall-macmini.sh   # (or the Linux equivalent — TODO)
```

Stops the service, deregisters via `config.sh remove` (needs a removal
token from the same GitHub UI), optionally deletes the runner directory.

## Adding a runner for another owner

A runner is registered to exactly one GitHub owner (org or personal
account). To serve a second owner from the same physical machine, run
the install script again with `ORG=<other-owner>` and a different
`RUNNER_HOME`:

```sh
ORG=apetresc RUNNER_HOME=$HOME/actions-runner-apetresc ./install-macmini.sh
```

You'll get a separate working dir, a separate launchd/systemd unit, and
a separate idle process (~40MB RSS each). The same labels can be
applied — workflows match runners by *label intersection*, not by
which owner the runner is registered to.

## Debug & ops cheat sheet

### macOS

```sh
# Status
launchctl print "gui/$(id -u)/actions.runner.${ORG}.${RUNNER_NAME}" | head -30
# Diagnostic logs
tail -f ~/actions-runner-${ORG}/_diag/Runner_*.log
# Force restart
launchctl kickstart -k "gui/$(id -u)/actions.runner.${ORG}.${RUNNER_NAME}"
# Workspace cleanup
rm -rf ~/actions-runner-${ORG}/_work
```

### Linux

```sh
# Status
sudo systemctl status actions.runner.${ORG}.${RUNNER_NAME}.service
# Logs
sudo journalctl -u actions.runner.${ORG}.${RUNNER_NAME}.service -f
# Restart
sudo systemctl restart actions.runner.${ORG}.${RUNNER_NAME}.service
```

## Security notes

- A runner runs as the configured user; jobs that workflow committers
  can land have full access to that user's home directory, ssh keys,
  Docker socket, etc.
- Trust boundary is **whoever can land code in caller repos**. For
  private repos with a small set of trusted committers (humans + your
  AI agents), this is fine.
- For runners attached to *public* repos: enable
  *Settings → Actions → Approval required for outside contributors*
  and/or use **runner groups** to restrict which repos can target which
  runners. Otherwise PR authors can submit `.github/workflows/evil.yml`
  that exfiltrates credentials.
- This repo (`apetresc/homelab-review-apps`) is public, but it's a
  *workflow library* — no runner attaches to it directly. Job
  execution always happens in the context of a private caller's
  `GITHUB_TOKEN`, scoped to that single workflow run.
