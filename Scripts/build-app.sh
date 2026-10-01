#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/manifest-cache"
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  echo 'Usage: bash Scripts/build-app.sh [debug|release]' >&2
  exit 2
fi
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --configuration "$configuration" --product ResearchCopilot
binary_dir="$(swift build --disable-sandbox --configuration "$configuration" --show-bin-path)"
app="${RESEARCH_COPILOT_APP_OUTPUT:-$PWD/build/ResearchCopilot.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/ResearchCopilot" "$app/Contents/MacOS/ResearchCopilot"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
mkdir -p "$app/Contents/Resources/Licenses"
for license in Resources/Licenses/*; do
  destination="$app/Contents/Resources/Licenses/$(basename "$license")"
  if [[ -f "$destination" ]]; then chmod u+w "$destination"; fi
  install -m 644 "$license" "$destination"
done
codesign --force --sign "${RESEARCH_COPILOT_SIGNING_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "Built: $app"
