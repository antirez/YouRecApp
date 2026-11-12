#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/yourec-video-effects.XXXXXX")
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
xcrun swiftc -swift-version 5 YouRec/ZoomTransition.swift YouRec/VideoEffects/VideoEffectModel.swift YouRec/VideoEffects/VideoEffectCatalog.swift YouRec/VideoEffects/VideoEffectMath.swift YouRec/VideoEffects/CaptureZoomHistory.swift Tests/VideoEffectModelTests.swift -o "$TEST_DIRECTORY/model-tests"
"$TEST_DIRECTORY/model-tests"
xcrun -sdk macosx metal -c YouRec/VideoEffects/VideoEffects.metal -o "$TEST_DIRECTORY/effects.air"
xcrun metallib "$TEST_DIRECTORY/effects.air" -o "$TEST_DIRECTORY/effects.metallib"
xcrun swiftc -swift-version 5 YouRec/VideoEffects/VideoEffectModel.swift YouRec/VideoEffects/VideoEffectCatalog.swift YouRec/VideoEffects/VideoEffectMath.swift YouRec/VideoEffects/MetalVideoEffects.swift Tests/VideoEffectGPUTests.swift -o "$TEST_DIRECTORY/gpu-tests"
YOUREC_EFFECTS_METALLIB="$TEST_DIRECTORY/effects.metallib" "$TEST_DIRECTORY/gpu-tests"
