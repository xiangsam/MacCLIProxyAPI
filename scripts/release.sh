#!/usr/bin/env bash
# Build a distributable MacCLIProxyAPI.app DMG + zip for users who do not compile
# from source. The app itself does not ship a core: users install one from the
# "版本" page after first launch (latest online, a specific version, or a local .tar.gz).
# Usage:
#   ./scripts/release.sh              # read version from project.yml
#   ./scripts/release.sh 0.1.0        # override marketing version label only (does not rewrite project.yml)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ ! -f project.yml ]]; then
  echo "error: run from MacCLIProxyAPI repo (project.yml missing)" >&2
  exit 1
fi

MARKETING_VERSION="${1:-}"
if [[ -z "${MARKETING_VERSION}" ]]; then
  MARKETING_VERSION="$(
    python3 - <<'PY'
import re
text = open("project.yml", encoding="utf-8").read()
m = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', text)
print(m.group(1) if m else "0.1.0")
PY
  )"
fi

BUILD_NUMBER="$(
  python3 - <<'PY'
import re
text = open("project.yml", encoding="utf-8").read()
m = re.search(r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', text)
print(m.group(1) if m else "1")
PY
)"

DIST_DIR="${ROOT}/dist"
DERIVED="${ROOT}/build-release"
APP_NAME="MacCLIProxyAPI"
APP_PATH="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
# ARCH_LABEL filled after build (may be universal)

echo "==> Version ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "==> Cleaning previous Release output"
rm -rf "${DERIVED}/Build/Products/Release/${APP_NAME}.app"
mkdir -p "${DIST_DIR}"

if command -v xcodegen >/dev/null 2>&1; then
  echo "==> xcodegen generate"
  xcodegen generate
else
  echo "==> xcodegen not found; using existing MacCLIProxyAPI.xcodeproj"
fi

echo "==> xcodebuild Release"
xcodebuild \
  -scheme MacCLIProxyAPI \
  -configuration Release \
  -derivedDataPath "${DERIVED}" \
  -destination "platform=macOS" \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app not found at ${APP_PATH}" >&2
  exit 1
fi

BIN="${APP_PATH}/Contents/MacOS/${APP_NAME}"
ARCH_INFO="$(lipo -info "${BIN}" 2>/dev/null || true)"
# lipo echoes the full binary path, which is under the builder's home; the notes
# get pasted onto a public Release page, so keep only the architecture list.
ARCH_LIST="$(echo "${ARCH_INFO}" | sed 's/.*are: //; s/.*is architecture: //' | xargs || true)"
if echo "${ARCH_INFO}" | grep -q 'x86_64' && echo "${ARCH_INFO}" | grep -q 'arm64'; then
  ARCH_LABEL="universal"
elif echo "${ARCH_INFO}" | grep -q 'arm64'; then
  ARCH_LABEL="arm64"
elif echo "${ARCH_INFO}" | grep -q 'x86_64'; then
  ARCH_LABEL="x86_64"
else
  ARCH_LABEL="$(uname -m)"
fi
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}-macos-${ARCH_LABEL}.zip"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"
SHA_PATH="${ZIP_PATH}.sha256"
DMG_NAME="${APP_NAME}-${MARKETING_VERSION}-macos-${ARCH_LABEL}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
DMG_SHA_PATH="${DMG_PATH}.sha256"
echo "==> Binary: ${ARCH_INFO}"

# Soft strip host paths check (should already be clean after #filePath removal)
if strings "${BIN}" 2>/dev/null | grep -E '/Users/[^/]+/' >/dev/null 2>&1; then
  echo "warning: binary still contains /Users/... path strings; review before sharing" >&2
else
  echo "==> host path scan: clean"
fi

echo "==> Packaging ${ZIP_NAME}"
rm -f "${DIST_DIR}/${APP_NAME}-${MARKETING_VERSION}-macos-"*.zip \
  "${DIST_DIR}/${APP_NAME}-${MARKETING_VERSION}-macos-"*.zip.sha256 2>/dev/null || true
(
  cd "$(dirname "${APP_PATH}")"
  ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${ZIP_PATH}"
)

echo "==> Packaging ${DMG_NAME}"
rm -f "${DIST_DIR}/${APP_NAME}-${MARKETING_VERSION}-macos-"*.dmg \
  "${DIST_DIR}/${APP_NAME}-${MARKETING_VERSION}-macos-"*.dmg.sha256 2>/dev/null || true
DMG_STAGE="$(mktemp -d)"
trap 'rm -rf "${DMG_STAGE}"' EXIT
ditto "${APP_PATH}" "${DMG_STAGE}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGE}" -ov -format UDZO "${DMG_PATH}" >/dev/null
rm -rf "${DMG_STAGE}"

# Portable checksums (macOS shasum)
(
  cd "${DIST_DIR}"
  shasum -a 256 "${ZIP_NAME}" | tee "$(basename "${SHA_PATH}")"
  shasum -a 256 "${DMG_NAME}" | tee "$(basename "${DMG_SHA_PATH}")"
)

# Everything below is boilerplate the script can derive; what actually changed in
# this version has to be written by hand, so pull it in from a tracked file rather
# than shipping notes that silently say nothing about the release.
HIGHLIGHTS_FILE="${ROOT}/docs/release-notes/${MARKETING_VERSION}.md"
if [[ -f "${HIGHLIGHTS_FILE}" ]]; then
  HIGHLIGHTS="$(cat "${HIGHLIGHTS_FILE}")"$'\n'
  echo "==> highlights: docs/release-notes/${MARKETING_VERSION}.md"
else
  HIGHLIGHTS=""
  echo "warning: no docs/release-notes/${MARKETING_VERSION}.md; notes won't say what changed" >&2
fi

cat > "${DIST_DIR}/RELEASE-NOTES-${MARKETING_VERSION}.md" <<EOF
# MacCLIProxyAPI ${MARKETING_VERSION}

${HIGHLIGHTS}
## 安装（无需源码构建）

下载其一即可：

- \`${DMG_NAME}\`（推荐）：打开后把 App 拖进「应用程序」
- \`${ZIP_NAME}\`：解压后把 App 拖进「应用程序」

校验（可选）：

\`\`\`bash
shasum -a 256 -c ${DMG_NAME}.sha256
# 或
shasum -a 256 -c ${ZIP_NAME}.sha256
\`\`\`

首次打开若提示「无法验证开发者」：

- 系统设置 → 隐私与安全性 → 仍要打开
- 或：\`xattr -dr com.apple.quarantine MacCLIProxyAPI.app\`

启动后到「版本」→「更新到最新版本」在线装上内核，再在首页启动内核。

## 说明

- 构建号：${BUILD_NUMBER}
- 架构：${ARCH_LABEL}（\`${ARCH_LIST}\`）
- 非 App Store 产品，不提供公证
- 应用本身不含内核，首次启动后在「版本」页联网安装（也可指定版本或本地 \`.tar.gz\`）

## 校验

见同目录 \`${DMG_NAME}.sha256\` / \`${ZIP_NAME}.sha256\`
EOF

echo
echo "Done."
echo "  App:  ${APP_PATH}"
echo "  Dmg:  ${DMG_PATH}"
echo "  Zip:  ${ZIP_PATH}"
echo "  SHA:  ${DMG_SHA_PATH}"
echo "        ${SHA_PATH}"
echo "  Notes:${DIST_DIR}/RELEASE-NOTES-${MARKETING_VERSION}.md"
echo
echo "Upload tip (GitHub Releases):"
echo "  1. git tag -a v${MARKETING_VERSION} -m 'MacCLIProxyAPI ${MARKETING_VERSION}'"
echo "  2. git push origin v${MARKETING_VERSION}"
echo "  3. Create a Release on the remote and attach the dmg + zip + both sha256 files"
echo "  4. Paste RELEASE-NOTES-${MARKETING_VERSION}.md as the release body"
