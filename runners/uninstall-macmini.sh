#!/usr/bin/env bash
#
# uninstall-macmini.sh — cleanly remove the eastbridge-academy GH Actions
# runner from this Mac. Stops the launchd service, deregisters from
# GitHub, and offers to delete the runner directory.
#
# Usage:
#   REMOVE_TOKEN=<token> ./uninstall-macmini.sh    # non-interactive
#   ./uninstall-macmini.sh                          # prompts for token
#
# Get a removal token from the runner's settings page on GitHub:
#   Settings → Actions → Runners → click runner → ⋯ → Remove → "Use this token"
set -euo pipefail

ORG="${ORG:-eastbridge-academy}"
RUNNER_HOME="${RUNNER_HOME:-${HOME}/actions-runner-${ORG}}"

if [ ! -d "${RUNNER_HOME}" ]; then
  echo "Nothing to uninstall: ${RUNNER_HOME} does not exist."
  exit 0
fi

cd "${RUNNER_HOME}"

if [ -z "${REMOVE_TOKEN:-}" ]; then
  echo "Get a removal token from:"
  echo "  https://github.com/organizations/${ORG}/settings/actions/runners"
  echo "  → click your runner → ⋯ → Remove → 'Use the following...'"
  echo
  read -r -s -p "Paste removal token (input hidden): " REMOVE_TOKEN
  echo
fi

if [ -f ./svc.sh ]; then
  echo "Stopping and uninstalling launchd service..."
  ./svc.sh stop || true
  ./svc.sh uninstall || true
fi

if [ -n "${REMOVE_TOKEN:-}" ] && [ -f ./config.sh ]; then
  echo "Deregistering runner from GitHub..."
  ./config.sh remove --token "${REMOVE_TOKEN}" || \
    echo "Warning: deregistration failed; remove manually in GitHub UI." >&2
fi

read -r -p "Delete ${RUNNER_HOME} entirely? [y/N] " yn
case "${yn}" in
  y|Y)
    cd /
    rm -rf "${RUNNER_HOME}"
    echo "Removed ${RUNNER_HOME}."
    ;;
  *)
    echo "Kept ${RUNNER_HOME}."
    ;;
esac
