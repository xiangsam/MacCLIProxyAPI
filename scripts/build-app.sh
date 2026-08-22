#!/usr/bin/env bash
# Build MacCLIProxyAPI into ./build so you can open it without hunting DerivedData.
# Usage:
#   ./scripts/build-app.sh           # build only
#   ./scripts/build-app.sh --open    # build, kill old process, open
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Debug}"
DERIVED="$ROOT/build/DerivedData"
APP_SRC="$DERIVED/Build/Products/$CONFIG/MacCLIProxyAPI.app"
APP_DST="$ROOT/build/$CONFIG/MacCLIProxyAPI.app"

command -v xcodegen >/dev/null && xcodegen generate

xcodebuild \
  -project MacCLIProxyAPI.xcodeproj \
  -scheme MacCLIProxyAPI \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build

if [[ ! -d "$APP_SRC" ]]; then
  echo "error: build succeeded but app missing at $APP_SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$APP_DST")"
rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"
# ditto preserves the source timestamps, which makes a fresh build look days old
# in Finder. Stamp it so sorting by date actually points at the newest build.
touch "$APP_DST"

VERSION="$(defaults read "$APP_DST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Built: $APP_DST"
echo "       v${VERSION} $CONFIG  $(date '+%m-%d %H:%M')"

# Ad-hoc `xcodebuild -derivedDataPath build` runs leave a second product tree next
# to this one, and every copy looks identical in Finder. Name them instead of
# letting them pile up unnoticed.
while IFS= read -r stray; do
  [[ "$stray" == "$APP_DST" || "$stray" == "$APP_SRC" ]] && continue
  echo "note:  另有旧副本 $stray"
done < <(find "$ROOT/build" -maxdepth 5 -name "MacCLIProxyAPI.app" -prune 2>/dev/null)

if [[ "${1:-}" == "--open" ]]; then
  killall MacCLIProxyAPI 2>/dev/null || true
  sleep 0.4
  open "$APP_DST"
fi
