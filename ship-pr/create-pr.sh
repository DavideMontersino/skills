#!/usr/bin/env bash
set -euo pipefail
[ $# -eq 0 ] && { echo "Usage: create-pr.sh [gh pr create args...]" >&2; exit 1; }
gh pr create "$@"
