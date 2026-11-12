#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIRECTORY=${YOUREC_TEST_DIRECTORY:-$(mktemp -d "${TMPDIR:-/tmp}/yourec-tests.XXXXXX")}
mkdir -p "$TEST_DIRECTORY"
if [[ "${1:-}" == "--effect-application" ]]; then
  ffmpeg -v error -y -i Tests/Fixtures/editor-fixture.mp4 -vf 'scale=216:384,fps=15' -c:v libx264 -c:a copy "$TEST_DIRECTORY/apply-fixture.mp4"
fi
if [[ "${1:-}" == "--night-fix-only" ]]; then scripts/make-night-fixture.sh "$TEST_DIRECTORY"; fi
if [ -z "${YOUREC_TEST_DIRECTORY:-}" ]; then trap 'rm -rf "$TEST_DIRECTORY"' EXIT; fi
# The shipped DeepFilter model is always exercised, including plain invocations.
if [ -z "${YOUREC_DFN3_MODEL:-}" ]; then
  xcrun coremlcompiler compile ThirdParty/DeepFilterNet3/DeepFilterNet3-Streaming.mlpackage "$TEST_DIRECTORY" > "$TEST_DIRECTORY/coreml-compile.log" 2>&1
  cp ThirdParty/DeepFilterNet3/DeepFilterNet3-DSP.json "$TEST_DIRECTORY/DeepFilterNet3-DSP.json"
  export YOUREC_DFN3_MODEL="$TEST_DIRECTORY"
fi
ffmpeg -y -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=4' -f lavfi -i 'sine=frequency=1000:sample_rate=48000:duration=4' -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$TEST_DIRECTORY/source.mp4"
ffmpeg -y -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=160x90:rate=24:duration=4' -c:v libx264 -pix_fmt yuv420p "$TEST_DIRECTORY/cadence24.mp4"
ffmpeg -y -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=160x90:rate=60:duration=2' -c:v libx264 -pix_fmt yuv420p "$TEST_DIRECTORY/cadence60.mp4"
ffmpeg -y -hide_banner -loglevel error -i "$TEST_DIRECTORY/source.mp4" -c:v copy -an "$TEST_DIRECTORY/silent.mp4"
if [[ "${1:-}" == "--project-recovery" ]]; then
  ffmpeg -y -hide_banner -loglevel error -i "$TEST_DIRECTORY/source.mp4" -c:v libx264 -g 30 -keyint_min 30 -sc_threshold 0 \
    -c:a copy -movflags +empty_moov+frag_keyframe+default_base_moof "$TEST_DIRECTORY/recovery-fragments.mov"
fi
ffmpeg -y -hide_banner -loglevel error -display_rotation 90 -i "$TEST_DIRECTORY/source.mp4" -c copy "$TEST_DIRECTORY/portrait.mp4"
ffmpeg -y -hide_banner -loglevel error -i "$TEST_DIRECTORY/portrait.mp4" -f lavfi -i 'sine=frequency=500:sample_rate=48000:duration=4' -map 0:v -map 1:a -c:v copy -c:a aac -shortest "$TEST_DIRECTORY/next-scene.mp4"
ffmpeg -y -hide_banner -loglevel error -i "$TEST_DIRECTORY/source.mp4" -af apad=pad_dur=0.12 -c:v copy -c:a aac "$TEST_DIRECTORY/audio-tail.mp4"
if [[ "${1:-}" == "--export-options" ]]; then
  # A different luminance on every successive frame exposes 30 fps duplication in a 60 fps file.
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i "nullsrc=s=180x320:r=60:d=2,geq=lum='if(mod(N,2),190,45)':cb=128:cr=128" \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$TEST_DIRECTORY/export-60.mp4"
  # Most frames last 3000/90000 seconds, every 18th lasts 3018/90000 (~29.82 fps).
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=320x180:r=30:d=3' \
    -vf 'settb=1/90000,setpts=3000*N+18*floor(N/18)' -fps_mode vfr -enc_time_base 1/90000 \
    -c:v libx264 -pix_fmt yuv420p -video_track_timescale 90000 "$TEST_DIRECTORY/export-vfr.mp4"
fi
for RN_SOURCE in denoise rnn rnn_data pitch kiss_fft celt_lpc; do
  xcrun clang -O3 -mmacosx-version-min=13.0 -IThirdParty/RNNoise/include -c "ThirdParty/RNNoise/src/$RN_SOURCE.c" -o "$TEST_DIRECTORY/$RN_SOURCE.o"
done
xcrun clang -O3 -mmacosx-version-min=13.0 -c ThirdParty/RNNoise/YouRecDenoiser.c -o "$TEST_DIRECTORY/adapter.o"
xcrun clang++ -std=c++17 -O3 -mmacosx-version-min=13.0 -c ThirdParty/LavaSR/LavaDSP.cpp -o "$TEST_DIRECTORY/lava.o"
xcrun clang++ -std=c++17 -O3 -mmacosx-version-min=13.0 -c ThirdParty/VoiceFixer/VoiceFixerDSP.cpp -o "$TEST_DIRECTORY/voicefixer.o"
xcrun clang++ -std=c++17 -O3 -mmacosx-version-min=13.0 -c YouRec/StabilizationMotion.cpp -o "$TEST_DIRECTORY/stabilization.o"
xcrun clang++ -std=c++17 -O3 Tests/StabilizationMotionTests.cpp "$TEST_DIRECTORY/stabilization.o" -o "$TEST_DIRECTORY/motion-tests"
"$TEST_DIRECTORY/motion-tests"
if [[ "${1:-}" == "--titles-only" ]]; then
  mkdir -p "$TEST_DIRECTORY/TitleFonts"; cp -R ThirdParty/TitleFonts/. "$TEST_DIRECTORY/TitleFonts/"
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i 'color=c=black:size=640x360:rate=30:duration=3' -c:v libx264 -pix_fmt yuv420p "$TEST_DIRECTORY/title-black.mp4"
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i 'color=c=black:size=640x360:rate=30:duration=3' -c:v libx265 -pix_fmt yuv420p10le -x265-params 'colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=error' -tag:v hvc1 "$TEST_DIRECTORY/title-hlg.mp4"
fi
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$TEST_DIRECTORY/modules" \
  ThirdParty/ZIPFoundation/*.swift YouRec/ProjectArchive.swift YouRec/EditorialTimeline.swift YouRec/ProjectRecovery.swift YouRec/RecordingSalvage.swift YouRec/Project.swift YouRec/PhotoClip.swift YouRec/EffectAnimation.swift YouRec/VideoBatchImport.swift YouRec/Subtitles.swift YouRec/SubtitleSpeech.swift YouRec/SubtitleRenderer.swift YouRec/TrackTimeline.swift YouRec/TimelineNavigation.swift YouRec/CoverFramePool.swift YouRec/TrackRenderer.swift YouRec/VideoEffects/VideoEffectCleanPlate.swift YouRec/VideoEffects/VideoEffectSubjectTracking.swift YouRec/VideoEffects/NightFix.swift YouRec/VideoEffects/VideoEffectSampling.swift YouRec/VideoEffects/VideoEffectTiming.swift YouRec/VideoEffects/VideoEffectModel.swift YouRec/VideoEffects/VideoEffectCatalog.swift YouRec/VideoEffects/VideoEffectMath.swift YouRec/VideoEffects/MetalVideoEffects.swift YouRec/VideoEffects/VideoEffectAssets.swift YouRec/VideoEffects/VideoEffectDepth.swift YouRec/VideoEffects/VideoEffectBackgroundAudio.swift YouRec/VideoEffects/VideoEffectCaptureAnalysis.swift YouRec/ImportedFonts.swift YouRec/TitleDesign.swift YouRec/StyledTextRenderer.swift YouRec/VideoTools.swift YouRec/ColorGrading.swift YouRec/LogColor.swift YouRec/Transitions.swift YouRec/TransitionRenderer.swift YouRec/VideoToolCompositor.swift YouRec/AudioCensor.swift YouRec/CutAudioEnvelope.swift YouRec/AudioGain.swift YouRec/WaveformDetail.swift YouRec/TimelineEditing.swift YouRec/TimelinePaste.swift YouRec/SourceMediaCache.swift YouRec/AudioDSP.swift YouRec/OfflineAudioPipeline.swift YouRec/StudioVoiceProcessor.swift YouRec/StudioRestorationProcessor.swift YouRec/DeepFilterVoiceProcessor.swift ThirdParty/DeepFilterNet3/DeepFilterNetEngine.swift YouRec/CaptureAudio.swift YouRec/CaptureSegmentWriter.swift YouRec/DualCameraLayout.swift YouRec/EffectApplication.swift YouRec/ExportCheckpoint.swift YouRec/MediaRenderer.swift YouRec/StabilizationPath.swift YouRec/VideoStabilizer.swift Tests/TitleDesignTests.swift Tests/CoreTests.swift Tests/TrackTimelineTests.swift Tests/TimelineClipboardChecks.swift Tests/MoveBoundaryChecks.swift Tests/TrackMediaTests.swift Tests/LegacyTimelineOracle.swift Tests/DeepFilterTests.swift Tests/StabilizationTests.swift Tests/VideoToolsTests.swift Tests/EffectAnimationChecks.swift Tests/TransitionTests.swift \
  Tests/NightFixTests.swift Tests/VideoEffectIntegrationTests.swift Tests/ProjectRecoveryTests.swift Tests/RecordingHistoryTests.swift Tests/PausesTests.swift Tests/SubtitleTests.swift -lc++ -import-objc-header YouRec/YouRec-Bridging-Header.h "$TEST_DIRECTORY"/*.o \
  -o "$TEST_DIRECTORY/core-tests"
xcrun -sdk macosx metal -c YouRec/VideoEffects/VideoEffects.metal -o "$TEST_DIRECTORY/effects.air"
xcrun metallib "$TEST_DIRECTORY/effects.air" -o "$TEST_DIRECTORY/effects.metallib"
export YOUREC_EFFECTS_METALLIB="$TEST_DIRECTORY/effects.metallib"
"$TEST_DIRECTORY/core-tests" "$TEST_DIRECTORY" "${1:-}"
