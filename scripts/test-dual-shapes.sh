#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/yourec-dual-shapes.XXXXXX")
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
xcrun swiftc YouRec/DualCameraLayout.swift YouRec/DualCameraMasks.swift Tests/DualCameraMaskTests.swift -o "$TEST_DIRECTORY/tests"
"$TEST_DIRECTORY/tests"
xcrun -sdk macosx metal -c YouRec/CameraCrop.metal -o "$TEST_DIRECTORY/crop.air"
xcrun -sdk macosx metallib "$TEST_DIRECTORY/crop.air" -o "$TEST_DIRECTORY/default.metallib"
xcrun swiftc YouRec/DualCameraLayout.swift YouRec/ZoomTransition.swift YouRec/VideoEffects/CaptureZoomHistory.swift YouRec/HorizonLevel.swift YouRec/DualFaceDetector.swift Tests/SingleCameraFollowTests.swift -o "$TEST_DIRECTORY/follow"
"$TEST_DIRECTORY/follow"
