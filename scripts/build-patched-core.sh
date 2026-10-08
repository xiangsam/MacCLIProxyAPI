#!/usr/bin/env bash
# Reproducible native macOS core; never rebuild an unrelated upstream revision.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  arm64|aarch64) GO_ARCH=arm64; ASSET_ARCH=aarch64 ;;
  amd64|x86_64) GO_ARCH=amd64; ASSET_ARCH=amd64 ;;
  *) echo "Unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
esac
read -r UPSTREAM COMMIT VERSION < <(python3 - "$ROOT" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
m=json.loads((root/'patches/cpa/version.json').read_text())
assert (root/'App/Resources/core-version.txt').read_text().strip()==m['version'], 'core version pin mismatch'
print(m['upstreamVersion'],m['upstreamCommit'],m['version'])
PY
)
SOURCE="$(mktemp -d)"
trap 'rm -rf "$SOURCE"' EXIT
git clone --quiet --depth 1 --branch "v$UPSTREAM" https://github.com/router-for-me/CLIProxyAPI.git "$SOURCE"
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$COMMIT" ]] || { echo "Upstream commit mismatch" >&2; exit 1; }
git -C "$SOURCE" apply --check "$ROOT/patches/cpa/native-responses-owner.patch"
git -C "$SOURCE" apply "$ROOT/patches/cpa/native-responses-owner.patch"
cd "$SOURCE"
go test ./sdk/cliproxy -run '^TestMacNativeResponsesOwnership$' -count=1
OUT="$ROOT/dist/patched-core/$ASSET_ARCH"
mkdir -p "$OUT"
CGO_ENABLED=1 GOOS=darwin GOARCH="$GO_ARCH" go build -trimpath \
  -ldflags="-s -w -X main.Version=$VERSION -X main.Commit=$COMMIT-mac -X main.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -o "$OUT/cli-proxy-api" ./cmd/server
cp LICENSE config.example.yaml "$OUT/"
cp "$ROOT/patches/cpa/version.json" "$OUT/mac-patch.json"
python3 "$ROOT/scripts/test-patched-core.py" "$OUT/cli-proxy-api"
tar -C "$OUT" -czf "$ROOT/dist/CLIProxyAPI_${VERSION}_darwin_${ASSET_ARCH}.tar.gz" \
  cli-proxy-api LICENSE config.example.yaml mac-patch.json
