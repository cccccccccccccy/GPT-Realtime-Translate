#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/manifest-cache"
developer_dir="$(xcode-select -p)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
flags=()
if [[ "$developer_dir" == /Library/Developer/CommandLineTools && -d "$testing_frameworks/Testing.framework" ]]; then
  flags=(-Xswiftc -F -Xswiftc "$testing_frameworks" -Xlinker -F -Xlinker "$testing_frameworks" -Xlinker -rpath -Xlinker "$testing_frameworks" -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib")
fi
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-xctest --enable-swift-testing "${flags[@]}" "$@"
