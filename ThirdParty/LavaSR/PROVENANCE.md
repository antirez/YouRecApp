# LavaSR v2 restoration

Upstream code: https://github.com/ysharma3501/LavaSR
Revision: `33ac040892519c1bb4aed7eb32e79af51cc29e2a`.
Weights: https://huggingface.co/YatharthS/LavaSR/tree/main/enhancer_v2
Upstream weights SHA-256:
`d100db961b2c125d77a52a12215c689e44cd9926a72f117513395b7e25e6de12`.
Apache-2.0 license is reproduced in LICENSE and the bundled third-party notices.

Conversion uses `scripts/convert-lavasr.py`, torch/torchaudio 2.7.0,
coremltools 9.0, and Vocos 0.1.0. The spectral network uses Float32, fixed input
shape 1×80×375, and separate real/imaginary outputs. The native frontend honors
the checkpoint's Slaney filterbank (44100-Hz bank, 0–8000 Hz) while processing
48-kHz waveforms, matching the upstream convention. STFT size 2048, hop 512,
periodic Hann window, and same padding are preserved.

Converted Core ML weight.bin SHA-256:
`1ef7557e72c9b2ee78ccb35cf3ab3400c0c73be1838ab16ff7dde52934f4d2cf`.

Measured conversion comparison on the Mac: maximum real/imaginary spectral error
0.000730/0.000771 on the deterministic conversion fixture. Native DSP versus
the reference on a four-second local excerpt: maximum log-mel error 0.000547;
maximum reconstructed waveform error 0.0000008494. These verify numerical
implementation, not perceptual quality.

YouRec's native DSP is an independent implementation of FFT, Slaney mel features,
and overlap/add reconstruction. The app uses four-second windows with 32 STFT hops
of context on each side and crops to the center. A complementary spectral merge
preserves original low/mid frequencies and introduces restoration between 4–6 kHz.
The initial wet amount is 35%; it can be changed or bypassed. This is bandwidth
restoration, not calibrated emulation of a named studio microphone, source-speaker
selection, or a verified room-dereverberation model. Listening evaluation remains
necessary, including clean full-band input and consonants.


Runtime identity validation (22 October): before loading, the app verifies the compiled weights against the pinned SHA-256 above and `model.mil` against `8a68fd3d717c6d5ae48318dc9dea6729ea8566b387e8cd296f56a11df57490de`. Validation is bounded to 1 MB reads and memoized per process. The same graph hash was verified for native tests and the device build. Compiler/model updates must deliberately revalidate this artifact. iOS Release no longer accepts a model-path environment override.
