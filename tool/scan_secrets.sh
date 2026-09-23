#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if ! command -v rg >/dev/null 2>&1; then
  echo 'Secret scan requires ripgrep (rg).' >&2
  exit 1
fi

# Print paths only. Never echo candidate credentials into CI logs.
pattern='-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36,}|AIza[0-9A-Za-z_-]{35}|"private_key"[[:space:]]*:[[:space:]]*"-----BEGIN'
if matches="$(rg -l --hidden --glob '!**/.git/**' --glob '!**/.dart_tool/**' --glob '!**/build/**' --glob '!**/.build/**' --glob '!**/node_modules/**' --glob '!**/.gradle/**' --glob '!**/Pods/**' --glob '!**/pubspec.lock' --glob '!**/package-lock.json' -- "$pattern" .)"; then
  :
else
  scan_status="$?"
  if [[ "$scan_status" -ne 1 ]]; then
    echo 'Secret scan could not complete.' >&2
    exit "$scan_status"
  fi
fi
if [[ -n "$matches" ]]; then
  echo 'Potential credentials in these files:' >&2
  echo "$matches" >&2
  exit 1
fi
echo 'No credential patterns found in source files.'
