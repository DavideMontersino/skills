#!/usr/bin/env bash
set -euo pipefail
[ $# -eq 0 ] && { echo "Usage: push.sh [git push args...]" >&2; exit 1; }
git push "$@"
