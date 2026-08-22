#!/usr/bin/env bash
# Re-sync this app's Codex model-catalog generation with upstream cc-switch
# (github.com/farion1231/cc-switch), which this app's catalog logic is ported from —
# see Core/Services/CodexModelCatalogWriter.swift and Core/Services/CodexModelCapabilities.swift.
#
# What this pulls in automatically:
#   - App/Resources/codex_deepseek_catalog_template.json (DeepSeek's official Codex
#     catalog, as cc-switch mirrors it)
#   - App/Resources/gpt5_5_template.json (ProxyChat's static last-resort template)
#   - App/Resources/codex_native_responses_template.json (the clean NativeResponses
#     template)
#
# What it can only flag for manual review (Rust logic/data this app ports by hand):
#   - CodexModelCapabilities.swift's CONFIRMED_TAILS text-only-model registry
#     (cc-switch: src-tauri/src/model_capabilities.rs)
#   - CodexModelCatalogWriter.swift's web-search reject host/model-prefix lists
#     (cc-switch: CODEX_WEB_SEARCH_REJECT_HOSTS / _MODEL_PREFIXES in codex_config.rs)
#   - CodexCatalogToolProfile's resolution rules and the strip list in
#     makeGenericEntry (cc-switch: codex_catalog_model_entry / resolve_codex_catalog_tool_profile)
#
# Usage:
#   ./scripts/sync-cc-switch-codex-catalog.sh          # sync at cc-switch's default branch
#   ./scripts/sync-cc-switch-codex-catalog.sh v1.2.3   # sync at a specific tag/ref
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${1:-main}"
RAW_BASE="https://raw.githubusercontent.com/farion1231/cc-switch/${REF}/src-tauri/src"
RESOURCES_DIR="${ROOT}/App/Resources"

fetch_json() {
  local remote_path="$1" local_name="$2"
  local url="${RAW_BASE}/${remote_path}"
  local dest="${RESOURCES_DIR}/${local_name}"
  local tmp
  tmp="$(mktemp)"
  echo "fetching ${url}"
  curl -fsSL "${url}" -o "${tmp}"
  python3 -m json.tool "${tmp}" >/dev/null || {
    echo "error: ${remote_path} is not valid JSON" >&2
    rm -f "${tmp}"
    exit 1
  }
  if [ -f "${dest}" ] && cmp -s "${tmp}" "${dest}"; then
    echo "  unchanged: ${local_name}"
    rm -f "${tmp}"
  else
    mv "${tmp}" "${dest}"
    echo "  updated:   ${local_name}"
  fi
}

fetch_json "resources/codex_deepseek_catalog_template.json" "codex_deepseek_catalog_template.json"
fetch_json "resources/gpt5_5_template.json" "gpt5_5_template.json"
fetch_json "resources/codex_native_responses_template.json" "codex_native_responses_template.json"

echo
echo "Diff the hand-ported Rust logic/data below against the Swift files listed above each block."
echo "This script does not rewrite Swift — only the bundled JSON templates are auto-applied."
echo

echo "--- model_capabilities.rs (compare against Core/Services/CodexModelCapabilities.swift) ---"
curl -fsSL "${RAW_BASE}/model_capabilities.rs" | sed -n '/const CONFIRMED_TAILS/,/^    \];/p'

echo
echo "--- codex_config.rs web_search blacklist (compare against CodexModelCatalogWriter.swift) ---"
curl -fsSL "${RAW_BASE}/codex_config.rs" | sed -n '/const CODEX_WEB_SEARCH_REJECT_HOSTS/,/^\];/p'
curl -fsSL "${RAW_BASE}/codex_config.rs" | sed -n '/const CODEX_WEB_SEARCH_REJECT_MODEL_PREFIXES/,/^    &\["/p' | head -5

echo
echo "--- codex_config.rs official vendor catalog hosts (compare against officialVendorCatalogHosts) ---"
curl -fsSL "${RAW_BASE}/codex_config.rs" | sed -n '/const CODEX_DEEPSEEK_OFFICIAL_CATALOG_HOSTS/p'

echo
if [ -n "$(cd "${ROOT}" && git status --porcelain -- App/Resources/codex_deepseek_catalog_template.json App/Resources/gpt5_5_template.json App/Resources/codex_native_responses_template.json 2>/dev/null)" ]; then
  echo "Bundled templates changed — review the diff, then rebuild (xcodegen generate) so the"
  echo "updated resources actually ship, and bump the regenerated ~/.codex/maccliproxy-model-catalog.json."
else
  echo "Bundled templates already match ${REF}."
fi
