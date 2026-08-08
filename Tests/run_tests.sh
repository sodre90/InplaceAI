#!/bin/bash
set -euo pipefail

# Test runner for InplaceAI.
#
# This machine's toolchain is Command Line Tools, which ships neither XCTest nor
# swift-testing, so `swift test` cannot run here. Instead we compile the units
# under test straight from Sources/ together with Tests/InplaceAITests/main.swift
# and run the resulting binary. The tests exercise the real production sources —
# there are no stubs or copies.
#
# Adding a new unit under test means adding its source file to UNITS_UNDER_TEST
# below, along with whatever it depends on. Files that touch Bundle.module (the
# SwiftPM-generated resource accessor) cannot be compiled this way.
#
# If Xcode is installed later, this can be replaced by a real `.testTarget` in
# Package.swift plus `swift test`.

cd "$(dirname "$0")/.."

UNITS_UNDER_TEST=(
    Sources/InplaceAI/Models/PromptLibrary.swift
    Sources/InplaceAI/Models/Suggestion.swift
    Sources/InplaceAI/Models/WritingTool.swift
    Sources/InplaceAI/Services/KeychainStore.swift
    Sources/InplaceAI/Services/SettingsStore.swift
    Sources/InplaceAI/Services/OpenAIService.swift
)

echo "🧪 Building app..."
swift build

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "🧪 Building tests..."
swiftc -swift-version 6 \
    "${UNITS_UNDER_TEST[@]}" \
    Tests/InplaceAITests/main.swift \
    -o "$BUILD_DIR/InplaceAITests"

"$BUILD_DIR/InplaceAITests"
