# VoiceFixer — Studio restoration

This is a full-band speech-restoration network and neural vocoder, not a model
of a particular microphone. It is distinct from YouRec's LavaSR detail filter.
The model targets noise, reverberation, clipping and limited bandwidth. Neural
resynthesis may alter vocal character or create artifacts; it is intended for
speech, not music. Quality is not guaranteed on every recording.

## Sources and licenses

- Architecture/code: https://github.com/haoheliu/voicefixer
- Pinned commit: `aae2253c85f97a87b844b6832384de249c23ab37`
- Upstream code: MIT (verbatim license in `LICENSE-code`).
- Published model weights: Haohe Liu, *VoiceFixer Model CheckPoint*, v3,
  https://doi.org/10.5281/zenodo.5600188
- Weights: **CC BY 4.0**, as stated by the author's Zenodo record (not MIT).
  https://creativecommons.org/licenses/by/4.0/
  Commercial use and redistribution are permitted with attribution. The
  converted weights retain that license. YouRec's original integration code
  is covered by the [project license](../../LICENSE).
- Changes: conversion to Core ML, mixed FP16/FP32 inference, fixed 256-frame
  mel context, overlapping native processing windows and wet/dry blending.
  No retraining. Attribution is included in the app and its filter details.

Original checkpoint SHA-256:

- `vf.ckpt`: `748411b70089cadf34a6c11054f95f3a454e614af562c23b13a82f6cb413109f`
- `model.ckpt-1490000_trimed.pt`: `9410d0b528c10a251ae947bd299d1939b0b3247df680c81c4164e94f5d87dc45`

Converted artifacts:

- `weights/weight.bin`: `67971970d18c06c1220dc63df11aa0186f787dc961c829dcd1624dad3d612360`
- compiled `model.mil`: `912bf44f5a89014f385a681fb7319af92fe9f19e22337c95fcddd7dac21760d2`
- `VoiceFixer-Mel.bin`: `ea5f198b442761e300d9f270090b5ed8c7a9936126b110b54cff03767198dcd9`

## Building

The approximately 200 MB `.mlpackage` is deliberately excluded from Git. Before
building the app on a new checkout, run `scripts/convert-voicefixer.py` with its
pinned Python dependencies and a scratch/cache directory. The script downloads
only the two author's checkpoints, checks their hashes before loading, checks
out the pinned architecture and produces `VoiceFixer.mlpackage` here. Xcode
compiles and bundles it. Installed builds work entirely offline; no account,
server processing or model download is required on the phone.

For a clean checkout on an Apple silicon Mac:

```sh
python3.12 -m venv .benchmarks/voicefixer-env
.benchmarks/voicefixer-env/bin/python -m pip install torch==2.7.0 torchaudio==2.7.0 coremltools==9.0 numpy==2.2.6 torchlibrosa==0.1.0 librosa==1.0.0 scipy matplotlib progressbar==2.5 pyyaml soundfile
.benchmarks/voicefixer-env/bin/python scripts/convert-voicefixer.py .benchmarks/voicefixer-cache
```

The first conversion needs network access. Re-running with a populated cache
reuses the upstream source and verifies both checkpoints before loading them.

## Runtime

The source remains immutable. Processing uses 44.1 kHz, a 2048-point periodic
Hann STFT with a 441-sample hop, and the author's 128-band HTK mel matrix. Native
features are checked against the original PyTorch frontend. The network takes
`[1,1,256,128]` and returns `[1,114660]`; output includes the vocoder padding and is centered to the 112455-sample
input as upstream does. Each 1.2-second hop retains 0.64 seconds of left context
and overlaps output for 70 ms. Resampling is streaming, inference memory is
bounded, exact duplicate channels share inference, and actual stereo channels
remain independent. Zero amount is an exact bypass. Intermediate windows are
cached for resume; source identity and the model/runtime version are in the
outer cache key. Preview and export consume the same cached result.

## Verification (2026-11-01)

- Native mel features versus the upstream frontend: relative RMS error
  `1.86e-6` on an eight-second speech excerpt.
- Core ML versus PyTorch waveform: relative RMS error about 3.3% with mixed
  precision (a numerical check, not a listening-quality score).
- Eight-second speech, bandwidth-limited speech, zero/50/100% amount,
  selected-range player composition and AAC export: passed.
- Cancel/resume, reused inference windows, complete reflected context on a
  partial final hop, exact sample counts down to one frame, stereo with one
  silent channel: passed.
- Measured energy-envelope lag on the test speech: 10 ms; no chunk-boundary
  impulse above the restored signal's normal derivative range in this sample.
- iPhone 14 Pro Max, 20-second mono sample: 13.72 s initially, 10.29 s on the
  final warmed run; restoration + EQ + gain took 10.84 s. Peak whole-app
  footprint on the final run: 590 MB. Thermal
  state remained nominal. These measurements are sample/device-specific.
- Public Enhance audio controls: add, play latest settings, bypass, reset,
  apply and reopen; portrait and landscape checked on the iPhone 14.

Perceptual quality still depends on the source and should be judged with Bypass;
these checks do not establish equivalence to a particular studio microphone.
