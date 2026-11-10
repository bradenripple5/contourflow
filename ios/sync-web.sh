#!/usr/bin/env bash
# Copies the single-file web app into the wrapper's bundle resources.
# Run this after editing contourflow.html, before building.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/ios/ContourFlow/Web"

if [[ ! -f "$root/contourflow.html" ]]; then
  echo "contourflow.html not found at $root" >&2
  exit 1
fi

mkdir -p "$dest"
cp "$root/contourflow.html" "$dest/contourflow.html"
echo "Synced contourflow.html -> ios/ContourFlow/Web/contourflow.html"
