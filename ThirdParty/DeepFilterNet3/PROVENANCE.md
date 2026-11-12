# DeepFilterNet3 native integration

Bundled as an optional voice-isolation model. Existing projects keep their selected model; new isolation stages still default to RNNoise. Model selection is undoable and persists across reopening.

- Swift runtime: Kyle Howells, DeepFilterNet-mlx, commit `c6c4b9dc98c62bfa90ed66c5fd4f5d54e88c7b4f`, Apache-2.0 / MIT. Source: https://github.com/kylehowells/DeepFilterNet-mlx
- Core ML conversion snapshot: `iky1e/DeepFilterNet3-Streaming-CoreML`, revision `dfc12319b3a62d09e9d51aace480c981067b9d7b`. Source: https://huggingface.co/iky1e/DeepFilterNet3-Streaming-CoreML
- Graph weights SHA-256: `1114ff972e25679e7f9707da85eee62659e1bdf50199035ecacba12e4ec0425d`. All downloaded files were checked against the pinned snapshot’s SHA256SUMS.
- Original model/project: https://github.com/Rikorose/DeepFilterNet (Apache-2.0 / MIT).
- Compiled graph (`model.mil`) SHA-256: `c2141d4890bbf6504ca58d1cac1ed65fd14ca6ef81e9f0423f668af6ba014dcd`, verified identical for this Xcode build on macOS, iOS and simulator.
- DSP JSON SHA-256: `3dd66deaeafd7612f7208bfbbccb9d1d9691296acbab313e17fb099d5cdfdf29`.

Adaptation removes MLX and online loading. ERB filterbanks are exported from the pinned `model.safetensors` keys `erb_fb` and `mask.erb_inv_fb`, matching the upstream Swift loader. They differ from the arrays with similar names in auxiliary.npz (maximum difference 1.0), so the auxiliary copies must not be substituted. Only initial normalization states are taken from auxiliary.npz. The Vorbis window uses the upstream Swift Float formula. All JSON arrays are validated for size and finite values.

The engine consumes 480-sample hops at 48 kHz, preserving recurrent state and draining lookahead at the end. Per-hop autorelease pools bound inference objects. Each channel has independent state; mixing reads dry samples at the output sample position. Explicit zero initialization, shape/type checks, FFT cleanup and one-stream lifecycle guards harden the upstream adapter. Whole-file inference was removed.

The app pins CPU execution and encodes that choice in the model runtime/cache identity. DSP bytes, graph and weights are verified before loading. The graph hash is tied to this conversion/compiler output; compiler updates must revalidate the artifact and update the identity deliberately. Xcode bundles the compiled model. Source-package compilation exists only for local development; temporary compiled assets are removed. Environment overrides are disabled in iOS Release.

Tests cover partial hops, silent and different stereo channels, half mixing, exact bypass, cancellation, repeated prepare/reset, model persistence, and independent timing correlation on a syllabic harmonic fixture. Physical iPhone 14 Pro Max optimized tests: 20 seconds in 0.593 s, repeated outputs byte-identical; the complete 48,988,096-frame stereo fixture through DeepFilterNet3 → LavaSR → EQ took 77.620 s with a 101,827,504-byte measured maximum footprint and nominal thermal state. These are engineering measurements; listening quality and room-echo removal remain under evaluation.

Runtime copyright: Kyle Howells 2026 (`LICENSE-MIT`, `LICENSE-APACHE`, `NOTICE`). Model copyright: Hendrik Schröter 2021 (`MODEL-LICENSE-MIT`). Both MIT notices are included in the app’s ThirdPartyNotices.txt. Upstream dual licensing also offers Apache-2.0.
