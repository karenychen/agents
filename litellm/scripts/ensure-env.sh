#!/usr/bin/env bash
# Create a local .env from the example if one is not present.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "$HERE/.env" ]; then
  cp "$HERE/.env.example" "$HERE/.env"
  chmod 600 "$HERE/.env"
  echo "created $HERE/.env from .env.example"
fi
