# Third-party source, models and test assets

In YouRec, open **Camera → Settings → More settings → Credits** for attributions
and offline license notices. The [bundled notices](YouRec/ThirdPartyNotices.txt)
include the license texts. Exact source revisions,
conversion details and weight checksums are recorded in each provenance file.

| Component / files | Version or revision | License and provenance |
| --- | --- | --- |
| `ThirdParty/RNNoise/src`, `include`, embedded pretrained weights | v0.1, `cdf196b1e9de2f8ff1003328ebf9a4316477429d` | BSD 3-Clause, with BSD 2-Clause component notices for KISS FFT, CELT/Opus and network routines. [COPYING](ThirdParty/RNNoise/COPYING), [provenance](ThirdParty/RNNoise/PROVENANCE.md) |
| `ThirdParty/DeepFilterNet3/DeepFilterNetEngine.swift` | `c6c4b9dc98c62bfa90ed66c5fd4f5d54e88c7b4f` | MIT / Apache-2.0; [MIT](ThirdParty/DeepFilterNet3/LICENSE-MIT), [Apache](ThirdParty/DeepFilterNet3/LICENSE-APACHE), [NOTICE](ThirdParty/DeepFilterNet3/NOTICE) |
| `ThirdParty/DeepFilterNet3` model and DSP data | conversion `dfc12319b3a62d09e9d51aace480c981067b9d7b` | [Model MIT license](ThirdParty/DeepFilterNet3/MODEL-LICENSE-MIT), [provenance and hashes](ThirdParty/DeepFilterNet3/PROVENANCE.md) |
| `ThirdParty/LavaSR` model | LavaSR v2, code revision `33ac040892519c1bb4aed7eb32e79af51cc29e2a` | [Apache-2.0](ThirdParty/LavaSR/LICENSE), [provenance and hashes](ThirdParty/LavaSR/PROVENANCE.md) |
| Vocos architecture in the converted LavaSR network | 0.1.0 | MIT, Charactr Inc. [Source](https://github.com/gemelo-ai/vocos), [conversion](scripts/convert-lavasr.py) |
| `ThirdParty/ZIPFoundation/*.swift` | 0.9.20, `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | [MIT](ThirdParty/ZIPFoundation/LICENSE), [provenance](ThirdParty/ZIPFoundation/PROVENANCE.md) |
| `ThirdParty/QwenASR/Sources` | speech-swift `a57702e6f523fa36ac5532d2bdc5f35f701a052c` | [Apache-2.0](ThirdParty/QwenASR/LICENSE); modified Qwen-only subset, [provenance](ThirdParty/QwenASR/PROVENANCE.md) |
| Optional Qwen3-ASR-0.6B MLX 4-bit weights/tokenizer | aufklarer conversion `bc441bd1e4295c1f42d9879f056049a925b6e013` | Apache-2.0; downloaded on request, not bundled; hashes in `SubtitleModelPack.swift` |
| MLX Swift / MLX / MLX C / metal-cpp / fmt / nlohmann-json | MLX Swift 0.31.4 and its vendored dependencies | MIT / Apache-2.0; [license texts](ThirdParty/QwenASR/DEPENDENCY-LICENSES.txt), exact SwiftPM revision in `Package.resolved` |
| PocketFFT and Norbert Juffa’s Metal exponential routine within MLX | As vendored by MLX Swift 0.31.4 | BSD 3-Clause and BSD 2-Clause respectively. Header notices and nlohmann/json’s embedded source credits are in the [bundled notices](YouRec/ThirdPartyNotices.txt). |
| Swift Numerics | 1.1.1 | Apache-2.0 with Runtime Library Exception; [license text](ThirdParty/QwenASR/DEPENDENCY-LICENSES.txt) |
| `Tests/Fixtures/astronaut.png` | scikit-image v0.25.2 copy of NASA photograph | Public domain; [source and attribution](Tests/Fixtures/README.md). Tests only; not shipped. |

The “Development tools” section of the [bundled notices](YouRec/ThirdPartyNotices.txt)
also credits the desktop model converters, test utilities and research baseline.

The video-effects Swift/Metal implementations, Pop palettes and procedural
backgrounds are original code/data. Person segmentation and tracking use Apple
Vision; no additional model weights are bundled or downloaded for video effects.
Metal, Core Image, AVFoundation, Vision and Core ML are system frameworks.
CorridorKey and other non-commercial or ShareAlike matting models are not included.

The [project license](LICENSE) covers YouRec’s original code and lists the component licenses.
Film references in History are factual
attributions, not endorsements or licenses to film footage. No reference-film
clips are bundled with the app or tests.

## VoiceFixer — Studio restoration

Architecture/code: [haoheliu/voicefixer](https://github.com/haoheliu/voicefixer),
commit `aae2253c85f97a87b844b6832384de249c23ab37`, MIT.
Weights: Haohe Liu, *VoiceFixer Model CheckPoint* v3,
[Zenodo DOI 10.5281/zenodo.5600188](https://doi.org/10.5281/zenodo.5600188),
**CC BY 4.0**.
YouRec converts the weights to Core ML and adds fixed-window inference,
overlap blending and native resampling. See `ThirdParty/VoiceFixer/PROVENANCE.md`
for pinned hashes, source, conversion instructions and limitations.

## Title fonts

Original unmodified TrueType files from the Google Fonts distribution, under SIL OFL 1.1. Exact file identities are in [SHA256SUMS](ThirdParty/TitleFonts/SHA256SUMS). The app includes each copyright and complete license under Credits → Fonts.

- [Atkinson Hyperlegible Next](https://github.com/google/fonts/tree/main/ofl/atkinsonhyperlegiblenext) · [license](ThirdParty/TitleFonts/atkinsonhyperlegiblenext/OFL.txt)
- [Barlow Condensed](https://github.com/google/fonts/tree/main/ofl/barlowcondensed) · [license](ThirdParty/TitleFonts/barlowcondensed/OFL.txt)
- [Archivo Black](https://github.com/google/fonts/tree/main/ofl/archivoblack) · [license](ThirdParty/TitleFonts/archivoblack/OFL.txt)
- [Source Serif 4](https://github.com/google/fonts/tree/main/ofl/sourceserif4) · [license](ThirdParty/TitleFonts/sourceserif4/OFL.txt)
- [Fraunces](https://github.com/google/fonts/tree/main/ofl/fraunces) · [license](ThirdParty/TitleFonts/fraunces/OFL.txt)
- [IBM Plex Mono](https://github.com/google/fonts/tree/main/ofl/ibmplexmono) · [license](ThirdParty/TitleFonts/ibmplexmono/OFL.txt)
- [Caveat](https://github.com/google/fonts/tree/main/ofl/caveat) · [license](ThirdParty/TitleFonts/caveat/OFL.txt)
