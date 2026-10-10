#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/tests"
# Run the same test cases without requiring Xcode's XCTest framework.
xcrun swiftc -O -swift-version 5 -D STANDALONE_TESTS -parse-as-library -module-cache-path "$ROOT/build/ModuleCache" \
    "$ROOT/Sources/Liubai/Book.swift" "$ROOT/Sources/Liubai/ReaderModel.swift" \
    "$ROOT/Sources/Liubai/Paging.swift" "$ROOT/Sources/Liubai/ReaderWindow.swift" \
    "$ROOT/Sources/Liubai/EdgeSpeech.swift" "$ROOT/Sources/Liubai/Listening.swift" \
    "$ROOT/Sources/Liubai/ReaderView.swift" \
    "$ROOT/Tests/LiubaiTests/BookTests.swift" "$ROOT/Tests/LiubaiTests/ListeningTests.swift" -o "$ROOT/build/tests/LiubaiTests"
"$ROOT/build/tests/LiubaiTests" "$@"
