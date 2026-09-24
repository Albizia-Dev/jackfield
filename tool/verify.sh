#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

stage="${1:-all}"
host="$(uname -s)"

notice() { echo "[jackfield] $*"; }
run() { notice "RUN $1"; shift; "$@"; }

on_exit() {
  local status="$1"
  notice 'SKIP live FCM, APNs, Web Push, HTTPS provider, device, lock-screen and force-stop gates: manual validation only.'
  if [[ "$status" -eq 0 ]]; then notice "PASS $stage"; else notice "FAIL $stage (exit $status)"; fi
}
trap 'on_exit $?' EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || { notice "Missing required command: $1" >&2; exit 1; }
}

consistency() {
  require dart
  run 'capability/workflow consistency' dart tool/check_capability_matrix.dart
  run 'canonical fixture semantics' dart tool/check_fixtures.dart
}

dart_gate() {
  require flutter
  run 'Flutter dependencies' flutter pub get
  run 'example dependencies' bash -c 'cd example && flutter pub get'
  run 'Dart format' dart format --output=none --set-exit-if-changed lib test tool example/lib example/test
  run 'Flutter analyze' flutter analyze --no-pub
  run 'Flutter tests' flutter test --no-pub
  run 'public DartDoc coverage' dart run tool/check_public_api_docs.dart
  run 'example analyze' bash -c 'cd example && flutter analyze --no-pub'
  run 'example tests' bash -c 'cd example && flutter test --no-pub'
  consistency
}

android_gate() {
  require flutter
  require java
  [[ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]] || { notice 'Android SDK path is required.' >&2; exit 1; }
  run 'Flutter dependencies' flutter pub get
  run 'example dependencies' bash -c 'cd example && flutter pub get'
  run 'example debug APK' bash -c 'cd example && flutter build apk --debug --no-pub'
  run 'Android plugin unit tests' bash -c 'cd example/android && ./gradlew :jackfield:testDebugUnitTest --console=plain'
}

apple_gate() {
  [[ "$host" == 'Darwin' ]] || { notice 'Apple gate requires macOS.' >&2; exit 1; }
  require flutter
  require swift
  require pod
  run 'Flutter dependencies' flutter pub get
  run 'example dependencies' bash -c 'cd example && flutter pub get'
  run 'Swift core tests' swift test --package-path darwin/jackfield
  run 'iOS pod compilation' pod lib lint ios/jackfield.podspec --allow-warnings --skip-tests --platforms=ios
  run 'macOS pod compilation' pod lib lint macos/jackfield.podspec --allow-warnings --skip-tests --platforms=osx
  run 'iOS simulator build' bash -c 'cd example && flutter build ios --simulator --debug --no-pub'
  run 'macOS example build' bash -c 'cd example && flutter build macos --debug --no-pub'
}

web_gate() {
  require flutter
  require node
  require npm
  run 'Web test dependencies' npm ci
  run 'Web worker tests' node --test tool/web_test/worker_test.mjs
  run 'Flutter dependencies' flutter pub get
  run 'example dependencies' bash -c 'cd example && flutter pub get'
  run 'Web JS build' bash -c 'cd example && flutter build web --release --no-pub --output build/web-js'
  run 'Web Wasm build' bash -c 'cd example && flutter build web --release --wasm --no-pub --output build/web-wasm'
  run 'Web bundle smoke' node tool/web_test/flutter_smoke.mjs example/build/web-js example/build/web-wasm
}

go_gate() {
  require go
  run 'Go example tests' bash -c 'cd server_example && go test ./...'
  run 'Go example vet' bash -c 'cd server_example && go vet ./...'
  run 'Go example build' bash -c 'cd server_example && go build ./...'
}

windows_scaffold_gate() {
  [[ -f windows/CMakeLists.txt && -f windows/jackfield_plugin.cpp && -f windows/jackfield_plugin_c_api.cpp ]] || {
    notice 'Windows scaffold files missing.' >&2; exit 1;
  }
  consistency
  notice 'Windows native behavior INCOMPLETE; scaffold and contract only.'
}

linux_scaffold_gate() {
  [[ -f linux/CMakeLists.txt && -f linux/jackfield_plugin.cc ]] || {
    notice 'Linux scaffold files missing.' >&2; exit 1;
  }
  consistency
  notice 'Linux native behavior INCOMPLETE; scaffold and contract only.'
}

case "$stage" in
  dart) dart_gate ;;
  android) android_gate ;;
  apple) apple_gate ;;
  web) web_gate ;;
  go) go_gate ;;
  windows-scaffold) windows_scaffold_gate ;;
  linux-scaffold) linux_scaffold_gate ;;
  secrets) run 'local source secret patterns' tool/scan_secrets.sh ;;
  all)
    consistency
    dart_gate
    if [[ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]]; then android_gate
    else notice 'SKIP Android build/unit: Android SDK path unavailable.'; fi
    web_gate
    go_gate
    windows_scaffold_gate
    linux_scaffold_gate
    run 'local source secret patterns' tool/scan_secrets.sh
    if [[ "$host" == 'Darwin' ]]; then apple_gate
    else notice 'SKIP Apple unit/build: macOS host required.'; fi
    ;;
  *) notice "Unknown stage: $stage" >&2; exit 2 ;;
esac
