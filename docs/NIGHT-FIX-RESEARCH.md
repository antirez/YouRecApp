# Night fix: restoration research and experiment plan

28 October 2026. Scope: an offline editor effect, prioritizing fidelity and
temporal stability over render speed. This document distinguishes published
results, implementation availability, and proposals for YouRec. A paper's score
is not evidence of quality on our recordings or of performance on an iPhone.

## Recommendation

Build a source-restoration stage with interchangeable experimental engines.
Compare motion-compensated temporal fusion plus spatial cleanup against learned
video restoration, using identical footage, exposure targets and output encoding.
Select the shipping engine from these comparisons. A hybrid may win; neither a
large network nor a hand-built filter deserves that assumption in advance.

Restoration should use past **and future** frames, reject unreliable motion
matches, preserve faces and fine texture, and lift shadows without turning every
night scene into daylight. Heavy processing is acceptable; ghosting, unstable
color, invented detail and loss of source timing are not.

Compare the original and restored clips with identical framing, exposure targets and export settings. Keep source footage intact.

## What the prior art tells us

Low-light enhancement involves several different tasks: reducing random and
structured noise, recovering usable contrast, handling color casts, suppressing
compression artifacts, and sometimes addressing motion blur. Increasing exposure
alone amplifies the defects. Denoising alone can leave a clean but unreadable
image. Spatial processing alone often removes texture or makes it fluctuate.

Cross-frame information is especially valuable when a weak detail is visible in
several frames. For independent noise and perfectly aligned samples, averaging
nine observations reduces noise standard deviation by a factor of three. That is
an ideal calculation, not a predicted gain on phone footage: compression and
the camera's image processing correlate noise, and moving or newly revealed
surfaces do not supply nine equivalent observations.

The most directly relevant paper is **Classic Video Denoising in a Machine
Learning World: Robust, Fast, and Controllable** (CVPR 2025). It combines flow
alignment, temporal Wiener filtering and spatial bilateral Laplacian filtering,
with learned parameters. Its training includes video compression, which the
authors find essential. It also acknowledges that a model trained for a known
camera/noise distribution can do better than its general pipeline. This supports
a controlled hybrid experiment, not a blanket preference for classical filters.
The authors have not released the implementation, citing copyright constraints.
[Paper](https://arxiv.org/html/2504.03136v1),
[project and release status](https://srameo.github.io/projects/levd/).

Professional tools provide useful quality references. Resolve combines temporal
and spatial reduction; Neat Video exposes noise profiling and temporal controls;
Topaz distinguishes denoising from detail-generating enhancement. They are
comparison targets, not libraries we can embed.
[Resolve](https://www.blackmagicdesign.com/products/davinciresolve/color),
[Neat Video](https://www.neatvideo.com/features),
[Topaz denoising](https://docs.topazlabs.com/topaz-video/filters/denoise).

Google's burst photography work demonstrates robust fusion with local motion
and occlusion handling. However, a still-photo capture system can choose its
exposures and retain RAW bursts. An editor cannot change the shutter time or
recover discarded sensor data from a compressed recording.
[Handheld Multi-Frame Super-Resolution](https://research.google/pubs/handheld-multi-frame-super-resolution/),
[Night Sight](https://research.google/blog/night-sight-seeing-in-the-dark-on-pixel-phones/).

## Candidate implementations and release checks

Licenses below describe the inspected upstream artifacts as of the research
date. A permissive source repository does not automatically settle an external
checkpoint's terms, dependency licenses, or dataset permissions. Pin every
shipping model and source revision and record their hashes and notices.

| Candidate | Why examine it | Availability and disposition |
| --- | --- | --- |
| [FastDVDnet, CVPR 2020](https://github.com/m-tassano/fastdvdnet) | Five-frame neural denoising without explicit optical flow; useful reproducible baseline. | MIT repository includes ordinary and clipped-noise checkpoints. Inspected code uses conventional convolutions and pixel shuffle. Synthetic-noise training is a material mismatch with compressed iPhone video; quality must be measured. |
| [BasicVSR++](https://github.com/ckkelvinchan/BasicVSR_PlusPlus) | Bidirectional recurrent restoration; includes denoising/deblurring support and same-resolution output. | Apache-2.0 code. Externally hosted checkpoint terms need separate verification. Deformable convolution and large intermediate states complicate Core ML deployment. Use a denoising checkpoint, not a super-resolution model by mistake. |
| [HVI-CIDNet, CVPR 2025](https://github.com/Fediory/HVI-CIDNet) | Separates color and intensity in low-light image enhancement; candidate illumination/spatial baseline. | MIT code; the [author's Hugging Face model card](https://huggingface.co/Fediory/HVI-CIDNet/blob/d31379c310b1df78aab80154e6b0b086493de4f7/README.md) also declares MIT. Single-image enhancement needs explicit temporal validation. |
| [Retinexformer, ICCV 2023](https://github.com/caiyuanhao1998/Retinexformer) | Strong image-enhancement reference based on illumination and reflectance. | MIT code; externally hosted weights require an artifact-specific check. Independent frame processing is insufficient evidence of video stability. |
| [BVI-Mamba](https://github.com/edhuang1/BVI-Mamba) | Alignment plus temporal feature processing; relevant video architecture. | Apache-2.0 source exists. No obvious pretrained-checkpoint link found in the inspected README. Deformable alignment/selective-scan operations need porting work. [Paper](https://arxiv.org/html/2604.23655v1). |
| [AnyMod-LLVE / AMNet, 2026](https://github.com/lhfgghc/LLVE-AMNet) | Supports RGB-only inference despite multimodal training; should not be dismissed as requiring an event camera. | Actual code and checkpoint links exist. README claims MIT, but its LICENSE link returned 404 and the root lacked that file. Resolve the complete license/checkpoint terms before adoption. [Paper](https://arxiv.org/abs/2606.11186). |
| [STCD, IJCAI 2025](https://github.com/xiaogang00/LLVE_STCD) | Separates illumination and texture with temporal constraints. | Code and weight links exist, but no license was found in the inspected repository. Research reference pending permission clarity. [Paper](https://ijcai.org/proceedings/2025/238). |
| [OpenNR](https://github.com/amateurmenace/Hush-OpenNR) | Accessible Metal implementation of temporal/spatial noise reduction; useful engineering reference. | Inspected LICENSE contains MIT plus the OpenFX BSD notice. A GitHub `NOASSERTION` label here is not evidence of a restrictive license. Its own examples/metrics are not independent quality validation. |

The newer papers broaden the design space but do not all offer a usable product
dependency:

| Research | Relevance | Release status checked |
| --- | --- | --- |
| [RetinexMCNet, ICCV 2025](https://openaccess.thecvf.com/content/ICCV2025/html/Wang_RetinexMCNet_A_Memory_Controller_Dominated_Network_for_Low-Light_Video_Enhancement_ICCV_2025_paper.html) | Recurrent memory for low-light enhancement. | [Repository](https://github.com/Meiao-W/RetinexMCNet) contained only a README promising a later release. |
| [VSRELL, CVPR 2026](https://openaccess.thecvf.com/content/CVPR2026/html/Hui_VSRELL_A_Simple_Baseline_for_Video_Super-Resolution_and_Enhancement_in_CVPR_2026_paper.html) | Joint video enhancement and resolution restoration. | [Repository](https://github.com/373hdj/VSRELL) contained README and MIT license, not executable model code. |
| [DWTA-Net, ICIP 2026](https://arxiv.org/pdf/2510.09450) | Short-term alignment with recurrent aggregation; relevant handling of motion and temporal information. | No verified deployable, licensed checkpoint established in this survey. |
| [TempRetinex](https://github.com/liyinibristol/TempRetinex) | Brightness normalization, occlusion awareness and reverse inference. | Code is present; README is incomplete and no root license was visible. |
| [VLLVE++, 2026](https://arxiv.org/abs/2602.08699) | Further work on temporal correspondence and residual degradation. | Paper reference; a licensed release of this exact version was not verified. |
| [CRISP, October 2026 preprint](https://arxiv.org/abs/2610.24299) | Recurrent enhancement and progressive illumination training. | Very recent preprint; no verified deployable weights/license established. Reported benchmark gains are not our measurements. |
| [BVI-CDM](https://github.com/lrr-rachel/BVI-CDM) | Diffusion-based low-light video research. | Apache-2.0 code; no obvious complete pretrained deployment package established. Evaluate fidelity before any product use. |

Diffusion or generative relighting may make attractive pictures while changing
the identity or texture of poorly observed objects. Default Night fix should
favor evidence-preserving restoration. If generative reconstruction is ever
considered, it needs a separate explicit mode and much stronger fidelity checks.
Even ordinary neural restoration must be checked for invented or erased texture.

Some familiar implementations conflict with the project's licensing policy:
[RVRT](https://github.com/JingyunLiang/RVRT/blob/main/LICENSE) is CC BY-NC 4.0;
[FloRNN](https://github.com/nagejacob/FloRNN/blob/main/LICENSE) is GPL-3.0;
[Zero-DCE](https://github.com/Li-Chongyi/Zero-DCE) restricts implementation use to
noncommercial purposes; the official
[BM3D/V-BM4D software](https://webpages.tuni.fi/foi/GCF-BM3D/) is restricted to
nonprofit education and scientific research. Do not vendor these implementations
or treat their public availability as permission to ship them.

RAW-specific research remains useful background, but is not a direct solution
for compressed camera footage: [Seeing Motion in the Dark](https://cchen156.github.io/paper/19ICCV_DRV.pdf),
[BRVE](https://github.com/ying-fu/BRVE), and the
[AIM 2025 RAW-video challenge](https://openaccess.thecvf.com/content/ICCV2025W/AIM/papers/Yakovenko_AIM_2025_Low-light_RAW_Video_Denoising_Challenge_Dataset_Methods_and_ICCVW_2025_paper.pdf).
RAW gains cannot be assumed after the phone has demosaiced, denoised, sharpened,
tone-mapped, subsampled and compressed the image. Truly clipped blacks, erased
texture and severe motion blur cannot be reliably reversed.

## Proposed restoration pipeline

1. **Read original frames and timestamps.** Respect range, transfer function,
   color primaries, orientation and bit depth. Restore before the existing
   creative-effect tone map. A model trained on gamma-encoded RGB requires an
   explicit adapter; do not feed it linear HDR textures unmodified.
2. **Analyze continuous shots.** Detect cuts and illumination/exposure changes;
   estimate spatially varying luma/chroma noise. Avoid treating foliage or hair
   as a flat noise patch. Estimate from multiple regions and times. Do not assume
   an imported file supplies camera ISO/shutter metadata.
3. **Find motion on robust guides.** A lightly cleaned, exposure-normalized guide
   can improve matching. Fusion still uses original samples so guide blur does
   not become the reconstructed detail. Compare global camera motion plus local
   flow against a dense-flow-only approach.
4. **Fuse selectively across time.** Begin experiments with five to nine frames,
   using both temporal directions. Weight by noise, matching residual, forward/
   backward consistency and image bounds. Reject occlusions, cuts and inconsistent
   illumination. Longer windows are optional for reliable static areas, not a
   universal quality setting. Fall back to current-frame spatial cleanup where
   correspondence is weak.
5. **Clean remaining spatial and color noise.** Compare a multiscale classical
   filter, a compact neural residual stage, and a complete learned video engine.
   Preserve natural skin texture; avoid sharpening residual noise. Separate
   luminance and chroma strengths internally.
6. **Recover readable lighting.** Apply a stable, low-frequency shadow/exposure
   adjustment with highlight protection. Preserve meaningful darkness, neon and
   mixed lighting. Keep a denoise-only setting. Stabilize adjustment parameters
   across time without suppressing real light changes.
7. **Cache a completed restoration.** Later grading, crop, transitions, text,
   grain and export operate on that same result. Never overwrite original media.

The first classical prototype should expose confidence and removed-detail views
for diagnosis. A good-looking still can conceal moving-edge ghosts. Deblurring
is a separate experiment; default sharpening is not a substitute.

## Fit with the existing editor

`SourceMediaCache` provides a useful pattern for source fingerprints, leases and
prepared media. `MediaRenderer.sourceTimeline` and `VideoToolCompositor` already
map timeline positions to source time. Restoration must happen before source
geometry, keying and layer compositing. The existing Step Printing frame average
deliberately smears motion and is unsuitable as a denoiser. Stabilization's global
motion estimate alone cannot align independently moving faces and hands.

The current creative pipeline converts HDR into a documented SDR highlight
shoulder (`docs/VIDEO-EFFECTS.md`). Night fix must not silently discard highlight
information before restoration. HDR preservation, or an explicitly declared SDR
result for an SDR-only model, needs an actual design and test rather than an
implicit conversion.

Read temporal context from the same original shot even if it extends just beyond
the selected edit range; modify only the requested output interval. Never use
the next unrelated timeline clip or another overlapping layer as a temporal
neighbor. Trims, reorders, speed changes, freeze frames and transitions must retain
their existing source mapping. Audio and project duration remain unchanged.

Persist parameters, source fingerprint, algorithm/model version and checkpoint
hash. Keyframes are evaluated in the effect's defined time domain. Cache keys
include those values and color configuration. Changing the interval must not
change the output of its overlapping interior through arbitrary initialization.
Recurrent engines need deterministic warm-up/checkpoints, or a documented
shot-level processing policy.

Process bounded chunks with temporal halos and spatial tile overlap. At 4K,
one RGBA16F frame occupies about 63.3 MiB; nine inputs alone require about 570 MiB,
before flow maps or neural activations. Whole-film frame dumps are unsuitable for
the phone. A new video-cache storage budget must be designed; the audio cache's
existing quota is not an appropriate default by accident. Use atomic completed
chunks, cancellation, restart recovery, cache eviction and source leases.

Apple provides [Vision optical flow](https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest).
Core ML portability needs an operator-by-operator check: deformable convolutions,
selective scans and dynamic hypernetwork weights are not automatically deployable.
[Core ML custom-operator guidance](https://apple.github.io/coremltools/docs-guides/source/custom-operators.html).
Rendering time and thermal behavior must be measured on iPhone 14 and 17 Pro.
Desktop GPU timings do not predict phone performance.

Long processing must checkpoint and resume. iOS continued-processing facilities
and GPU availability are conditional; check supported resources and expiration
at runtime. Do not promise arbitrary GPU rendering while locked merely because
the effect is offline.
[Apple background GPU resource](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/resources/gpu),
[continued-processing session](https://developer-mdn.apple.com/videos/play/wwdc2025/227/?time=515).

## User experience proposal

Place **Night fix** with correction/restoration tools, with an editor-only badge.
Start from automatic analysis and three understandable controls: **Brightness**,
**Noise reduction**, and **Preserve texture**. Expose extra color-noise/motion
controls only if tests show they help users. Brightness zero must remain useful.

Let the user render a short full-quality sample around the playhead, loop it,
hold to see the original and inspect at 100% zoom. Compare the same timestamps
and framing. Show clearly whether the scope is a marked range, selected clip(s),
or the whole project. Applying starts a cancellable preparation with progress;
retain the last valid result until its replacement is complete. The final editor
preview and export use the same prepared frames. Removal and parameter changes
remain undoable after reopening the project.

## Quality evaluation before choosing a shipping engine

The first paired experiment is a classical engine versus the MIT FastDVDnet
baseline. It is not a declaration that FastDVDnet is the best neural method.
A stronger learned candidate must be considered before settling the final effect,
especially if the baseline fails on codec-correlated noise. Training/adaptation
should model actual phone processing, H.264/H.265 compression and chroma loss.

| Check | Required evidence |
| --- | --- |
| Actual improvement | Blind comparisons at comparable brightness, both full-frame and 100% crops. Compare with simple exposure-only output as well as the untouched original. |
| Fidelity | Eyes, teeth, hair, beard, fabric, lettering and thin edges remain recognizable and do not acquire fabricated detail. Inspect removed-detail residuals. |
| Motion | Speech, blinking, hands, turning heads, walking people and pans show no trails or face deformation. Test new surfaces at occlusions. |
| Temporal stability | Motion/occlusion-aware residuals plus normal-speed playback. Raw frame differences alone reward frozen or blurred images and are insufficient. |
| Lighting | Shadows improve without bleaching night, shifting skin, clipping lights or pumping exposure. Include changing illumination and LED flicker. |
| Edit correctness | Identical source timestamps, frame count policy, audio sync, dimensions and duration; no cross-cut blending; correct overlaps, holds, speed and split/rejoin behavior. |
| Reproducibility | Same algorithm/weights/settings reproduce rendered pixels within a specified numerical tolerance; compare decoded frames, not container-file bytes. Test chunk/tile seams and resumed processing. |
| Device operation | Full-resolution quality, memory peak, sustained thermal behavior, storage, cancellation and recovery on the physical supported phones. |

Use public datasets only after checking their exact terms.
[BVI-RLV](https://lrr-rachel.github.io/BVI-RLV/) is particularly relevant because
it includes registered real low-light video rather than only synthetic noise.
[DID](https://github.com/ciki000/DID) adds dynamic cases.
[OLiVES](https://arxiv.org/abs/2610.20501) is recent outdoor-video research worth
following. These do not replace testing our own encoded phone footage.
Do not use ground-truth-derived brightness normalization in an evaluation meant
to predict real app behavior. Several research evaluation scripts offer such
options; a user supplies only the dark recording.

The custom set should span both phones, several skin tones, mixed/neon lighting,
moving hair/hands, foliage, small text, lit windows, deep black areas, camera
switches, auto-exposure changes, SDR/HDR and portrait/landscape. Static controlled
scenes can provide high-SNR references; a long exposure of a moving subject is
not a valid sharp ground truth. Published metrics on incompatible datasets must
not be combined into a single ranking.

The selected algorithm and its controls are documented in [Night fix](NIGHT-FIX.md).
