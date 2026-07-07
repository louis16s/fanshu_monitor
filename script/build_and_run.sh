#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "$ROOT_DIR/.." && pwd)"
PROJECT="$ROOT_DIR/番薯monitor.xcodeproj"
SCHEME="番薯Monitor"
APP_NAME="番薯Monitor"
BUNDLE_ID="com.fanshu.monitor"
OUTPUTS_DIR="$WORKSPACE_DIR/outputs"
APP_BUNDLE="$OUTPUTS_DIR/$APP_NAME.app"
ZIP_PATH="$OUTPUTS_DIR/$APP_NAME.zip"
BACKUP_DIR="$OUTPUTS_DIR/backups/$(date +%Y%m%d-%H%M%S)-before-run-refresh"
BUILD_LOG="${TMPDIR:-/tmp}/fanshu-monitor-xcodebuild.log"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

build_release() {
  mkdir -p "$OUTPUTS_DIR"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    build >"$BUILD_LOG" 2>&1 || {
      echo "Build failed. Recent log: $BUILD_LOG" >&2
      tail -80 "$BUILD_LOG" >&2
      exit 1
    }

  local built_products_dir
  built_products_dir="$(
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Release \
      -showBuildSettings 2>/dev/null |
      awk -F'= ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}'
  )"
  local built_app="$built_products_dir/$APP_NAME.app"
  if [[ ! -d "$built_app" ]]; then
    echo "Built app not found: $built_app" >&2
    exit 1
  fi

  mkdir -p "$BACKUP_DIR"
  if [[ -d "$APP_BUNDLE" ]]; then
    ditto "$APP_BUNDLE" "$BACKUP_DIR/$APP_NAME.app"
    rm -rf "$APP_BUNDLE"
  fi

  ditto "$built_app" "$APP_BUNDLE"
  touch "$APP_BUNDLE"
  xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f -R -trusted "$APP_BUNDLE" 2>/dev/null || true

  rm -f "$ZIP_PATH"
  (
    cd "$OUTPUTS_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip"
  )
}

open_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.3
  /usr/bin/open -n "$APP_BUNDLE"
}

build_release

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    usage
    exit 2
    ;;
esac
