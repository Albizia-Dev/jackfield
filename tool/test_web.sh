#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

node --test tool/web_test/worker_test.mjs
flutter test
(
  cd example
  flutter build web --release --no-pub --output build/web-js
  flutter build web --release --wasm --no-pub --output build/web-wasm
)
node tool/web_test/flutter_smoke.mjs example/build/web-js example/build/web-wasm
