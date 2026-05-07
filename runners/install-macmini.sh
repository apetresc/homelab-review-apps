#!/usr/bin/env bash
#
# install-macmini.sh — register and install a self-hosted GitHub Actions
# runner on this Mac, for any GitHub org or user (defaults to
# eastbridge-academy; override with ORG=<other>).
#
# Idempotent: re-running with a fresh registration token replaces the
# existing registration (--replace), so this same script handles both
# first-time install and re-registration.
#
# Usage:
#   RUNNER_TOKEN=<token> ./install-macmini.sh                # non-interactive
#   ./install-macmini.sh                                      # prompts for token
#   ORG=apetresc RUNNER_HOME=$HOME/actions-runner-personal \
#       ./install-macmini.sh                                  # second runner for another owner
#
# Get a registration token (valid ~1 hour) at:
#   https://github.com/organizations/${ORG}/settings/actions/runners/new
# (or the user-account equivalent for personal accounts).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORG="${ORG:-eastbridge-academy}"
RUNNER_HOME="${RUNNER_HOME:-${HOME}/actions-runner-${ORG}}"
RUNNER_NAME="${RUNNER_NAME:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
RUNNER_VERSION="${RUNNER_VERSION:-2.334.0}"
LABELS="${LABELS:-self-hosted,macmini,orbstack}"

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

# Sanity check: registration tokens are short alphanumeric (~29 chars,
# typically starting with 'A'). SHA-256 hashes are 64 hex chars. Catch
# the most common foot-gun before sending the request.
if [ ${#RUNNER_TOKEN} -eq 64 ] && [[ "${RUNNER_TOKEN}" =~ ^[a-fA-F0-9]+$ ]]; then
  echo "Error: that looks like a SHA-256 hash, not a registration token." >&2
  echo "On the runner-add page, scroll past the 'Download' section to the" >&2
  echo "'Configure' section and copy the value after '--token'." >&2
  exit 1
fi

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)  PLATFORM=osx-arm64 ;;
  Darwin/x86_64) PLATFORM=osx-x64 ;;
  *)
    echo "Error: install-macmini.sh only supports macOS (got $(uname -s)/$(uname -m))" >&2
    exit 1
    ;;
esac

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

# If a service from a prior install is running, stop it before re-registering
# so config.sh doesn't trip on an active connection.
if [ -f ./svc.sh ] && ./svc.sh status 2>/dev/null | grep -qi "started\|running"; then
  echo "Stopping existing service before re-registration..."
  ./svc.sh stop || true
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

# Inject env vars (PATH, DOCKER_HOST) for jobs.
cp -f "${SCRIPT_DIR}/runner.env" "${RUNNER_HOME}/.env"

echo "Installing launchd service..."
./svc.sh install
./svc.sh start

echo
echo "Runner '${RUNNER_NAME}' installed and started."
echo "Status: $(./svc.sh status 2>&1 | head -1)"
echo "Verify: https://github.com/organizations/${ORG}/settings/actions/runners"
echo "Diag logs: ${RUNNER_HOME}/_diag/Runner_*.log"
