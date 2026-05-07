#!/usr/bin/env bash
#
# install-swarm-manager.sh — register and install a self-hosted GitHub
# Actions runner on a Linux Docker Swarm manager node, for any GitHub
# org or user (defaults to eastbridge-academy; override with ORG=<other>).
#
# Run THIS SCRIPT ON THE SWARM MANAGER, not from a remote host.
#
# Idempotent: re-running with a fresh registration token replaces the
# existing registration (--replace).
#
# Usage:
#   RUNNER_TOKEN=<token> ./install-swarm-manager.sh
#   ./install-swarm-manager.sh                  # prompts for token
#   ORG=<other-owner> ./install-swarm-manager.sh
#
# Prerequisites on the manager:
#   - Linux x86_64 or arm64.
#   - systemd (for ./svc.sh install).
#   - Current user in the docker group (so the runner can hit
#     /var/run/docker.sock without sudo). Verify with: id -nG | grep docker
#   - GHCR pull credentials provisioned for `--with-registry-auth` to
#     propagate across Swarm nodes:
#       docker login ghcr.io -u <user> -p <PAT-with-read:packages>
#   - sudo (for ./svc.sh install — installs a systemd unit).
#
# Get a registration token (valid ~1 hour) at:
#   https://github.com/organizations/${ORG}/settings/actions/runners/new
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORG="${ORG:-eastbridge-academy}"
RUNNER_HOME="${RUNNER_HOME:-${HOME}/actions-runner-${ORG}}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)}"
RUNNER_VERSION="${RUNNER_VERSION:-2.334.0}"
LABELS="${LABELS:-self-hosted,swarm}"

if [ -z "${RUNNER_TOKEN:-}" ]; then
  echo "Get a registration token from:"
  echo "  https://github.com/organizations/${ORG}/settings/actions/runners/new"
  echo "(the value after '--token', NOT the SHA-256 hash shown above it)"
  echo
  read -r -s -p "Paste registration token (input hidden): " RUNNER_TOKEN
  echo
fi

# Strip whitespace and CR/LF that some terminal pastes append.
RUNNER_TOKEN="${RUNNER_TOKEN//[$'\t\r\n ']/}"

if [ -z "${RUNNER_TOKEN:-}" ]; then
  echo "Error: RUNNER_TOKEN is required" >&2
  exit 1
fi

# Sanity check: tokens are short alphanumeric (~29 chars). SHA-256 hashes
# are 64 hex chars. Catch the most common foot-gun before sending the
# request to GitHub.
if [ ${#RUNNER_TOKEN} -eq 64 ] && [[ "${RUNNER_TOKEN}" =~ ^[a-fA-F0-9]+$ ]]; then
  echo "Error: that looks like a SHA-256 hash, not a registration token." >&2
  echo "On the runner-add page, scroll past the 'Download' section to the" >&2
  echo "'Configure' section and copy the value after '--token'." >&2
  exit 1
fi

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  PLATFORM=linux-x64 ;;
  Linux/aarch64) PLATFORM=linux-arm64 ;;
  *)
    echo "Error: install-swarm-manager.sh only supports Linux (got $(uname -s)/$(uname -m))" >&2
    exit 1
    ;;
esac

# Pre-flight: must be in docker group.
if ! id -nG | tr ' ' '\n' | grep -qx docker; then
  echo "Error: $(whoami) is not in the docker group on $(hostname -s)." >&2
  echo "Add and re-login: sudo usermod -aG docker $(whoami) && newgrp docker" >&2
  exit 1
fi

# Pre-flight: docker socket must be reachable.
if ! docker info >/dev/null 2>&1; then
  echo "Error: \`docker info\` failed — the Docker daemon isn't reachable." >&2
  exit 1
fi

# Pre-flight: must be a Swarm manager (not just any node).
if ! docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null | grep -qx true; then
  echo "Warning: this host doesn't report itself as a Swarm manager." >&2
  echo "  docker info | grep -A2 Swarm" >&2
  echo "  Continuing anyway — override this check by deleting it from the script." >&2
fi

ARCHIVE="actions-runner-${PLATFORM}-${RUNNER_VERSION}.tar.gz"
ARCHIVE_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${ARCHIVE}"

mkdir -p "${RUNNER_HOME}"
cd "${RUNNER_HOME}"

if [ ! -f config.sh ] || ! ./config.sh --version 2>/dev/null | grep -q "${RUNNER_VERSION}"; then
  echo "Downloading actions-runner v${RUNNER_VERSION} (${PLATFORM})..."
  curl -fsSL -o "${ARCHIVE}" "${ARCHIVE_URL}"
  tar xzf "${ARCHIVE}"
  rm -f "${ARCHIVE}"
fi

# Stop any pre-existing systemd service before re-registering.
SVC_NAME="actions.runner.${ORG}.${RUNNER_NAME}.service"
if systemctl --quiet is-active "${SVC_NAME}" 2>/dev/null; then
  echo "Stopping existing service ${SVC_NAME} before re-registration..."
  sudo ./svc.sh stop || true
fi

echo "Registering runner '${RUNNER_NAME}' to ${ORG}..."
./config.sh \
  --url "https://github.com/${ORG}" \
  --token "${RUNNER_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${LABELS}" \
  --runnergroup default \
  --replace \
  --unattended \
  --disableupdate

echo "Installing systemd service (will prompt for sudo)..."
sudo ./svc.sh install "$(whoami)"
sudo ./svc.sh start

echo
echo "Runner '${RUNNER_NAME}' installed and started."
echo "Status:"
sudo ./svc.sh status 2>&1 | head -3
echo
echo "Verify: https://github.com/organizations/${ORG}/settings/actions/runners"
echo "Logs:   sudo journalctl -u ${SVC_NAME} -f"
