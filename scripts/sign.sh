#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: scripts/sign.sh <path> [path ...]" >&2
  exit 64
fi

IDENTITY="${CODESIGN_IDENTITY:--}"

for path in "$@"; do
  codesign --force --sign "$IDENTITY" "$path"
  xattr -cr "$path"
done
