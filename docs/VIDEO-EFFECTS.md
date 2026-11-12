# Video effects — implementation specification

25 October 2026. User specification and subsequent decisions govern this work.

As of 7 November, the camera and editor pickers group effects under
Color & style, Camera & frame, Time and Background. The Applied list contains
the individual effects, including those saved by the former Silent Era preset.

### Crop rotation — 26 October

Rotation is now a Crop setting: −180°…180°, a clockwise 90° button, tap the
angle to reset, and Reset framing for angle/zoom/position together. The output
shape stays unchanged. The rotated window automatically fits inside the source;
pinch, drag and position controls account for rotation and mirroring. Text and
image overlays keep their output-space placement. Rotation follows the existing
selection scope, Apply/Cancel, effect-bubble editing and persistent Undo/Redo.

The same affine transform drives the framing canvas, native AVFoundation
composition and the custom compositor. Dutch Angle, Noir Tilt, their protocol
definition and shader branches are removed. Loading skips unknown video-effect
IDs in source recipes, all history entries, recording settings and recovered
recording sidecars. Recognized effects still undergo normal validation.

## Scope and targets

Twenty effects: Jump Cut is explicitly removed; existing Split and Pauses remain.
Prioritize iPhone 14 and 17 Pro. Older hardware support is retained only when
trivial, without a separate compatibility project. Air and the foldable Duo are additional targets. Apple confirms Duo availability
from 23 October 2026. Actual Duo simulator testing requires Xcode 27.1 and iOS
27.1; this Mac currently has Xcode 26.6 / iOS 26.5. The installed tooling cannot
validate native Duo poses or its new vertical toolbars.
Simulator testing covers layout and behavior, never hardware camera/GPU promises.
Pop palettes include authored palettes and reusable palettes sampled from video.
Recording retains all camera and zoom controls; no depth-recording mode is offered.
Depth-dependent editor paths use compatible original Cinematic imports. Simulated
Dolly Zoom falls back to person segmentation when usable depth is absent.

| ID | Name | Family | Capture | Editor |
| --- | --- | --- | --- | --- |
| colorCorrection | Color Correction | Color | yes | yes |
| silentTint | Silent Tint | Color | yes | yes |
| threeStrip | Three-Strip | Color | yes | yes |
| bleachBypass | Bleach Bypass | Color | yes | yes |
| dayForNight | Day for Night | Color | yes | yes |
| colorIsolation | Color Isolation | Color | yes | yes |
| noir | Noir | Color | yes | yes |
| expressionism | Expressionism | Color | yes | yes |
| quantization | Quantization | Quantization | yes | yes |
| dollyZoom | Dolly Zoom | Camera | tracked optical/digital move | two-layer simulation |
| crashZoom | Crash Zoom | Camera | trigger and tracked target | timed move |
| widescreen | Widescreen 1953 | Frame | yes | yes; depth-only oval bokeh |
| freezeFrame | Freeze Frame | Time | no | insert full-resolution hold |
| stepPrinting | Step Printing | Time | no | block accumulation |
| undercranking | Undercranking | Time | cadence preview | cadence and speed |
| halation | Halation | Texture | yes | yes |
| sixteenMM | 16mm | Texture | yes | yes |
| superEight | Super 8 | Texture | yes | yes |
| chromaKey | Chroma Key | Key | yes | yes |
| autoBackground | Auto Background | Key | yes | yes |

The source text says six families but includes Frame separately; the model has
seven. All live-capable image effects are available in the editor as well.
Existing specifically named transitions are outside this new-effects naming rule.
New effect labels use technique names only; film titles occur only in History.

## Persistence, editing and capture

Original camera media stays untouched. Recording saves its effect recipe beside
the raw take and attaches that recipe to the new timeline clip. Re-export never
applies a baked look twice. All saved parameters are typed and versioned, with
source-time keyframes (numeric/color interpolate; toggles/pickers/media step).
Structural timeline changes such as freeze duration are edited as durations.
New document version prevents older builds discarding these effects silently.
New media/analysis sidecars must participate in archive/export, checksums and
missing-file validation; removing a look must not delete a historical asset.

Pipeline: Key → Camera → Color → Quantization → Texture → Frame. Stable order
within each family; bars are last. Temporal transforms map the input sequence
before shading, while animated grain uses presentation-frame time. Intensity
mixes untouched input with output once per effect, except structural time and
camera transforms where it is hidden. A zero-intensity image effect is identity.

Raw capture always has priority. GPU work and Vision run outside the recorder's
sample/audio queue. No effect failure can terminate a take. A budget overrun
selects an explicitly recorded lighter configuration, so export can reproduce it.
Do not claim all combinations meet budget until measured on physical hardware.

## Color and math contracts

Core Video/Metal textures and Core Image color management feed linear BT.709
rgba16Float working textures. SDR inputs preserve their display-referred values.
HDR input uses a documented highlight shoulder: identity through linear luma
0.75, then 0.75 + 0.25 * (1 − exp(−(Y−0.75)/0.25)); scale RGB by the luma ratio,
then compress out-of-gamut chroma toward that luma before clamping. This creative
pipeline deliberately produces an SDR look; untouched HDR footage retains the
existing HDR path. Never interpret raw HLG/Log code values as linear samples.
Unsupported Log needs an explicit transform, not a guessed grade.

Luma is 0.2126R + 0.7152G + 0.0722B. Keyer unmixing is corrected: C−(1−a)S is
already premultiplied foreground; either add it directly to (1−a)B or divide by
a before straight-color despill and multiply once at compositing. Recompute
unmixing against the final refined alpha. Person holdouts protect interiors,
not hair edges. Invalid/missing masks are surfaced, never treated as all-black.

Tracked dolly zoom compensates the already-applied zoom: target z = current z
* reference observed height / current observed height. Using initial z on every
frame would create feedback oscillation. One physical lens stays selected during
the move. Loss for 0.5 s stops with a 0.3 s ease-out. Zoom engine remains shared.

Undercrank/Super 8 frame sampling uses elapsed time at the requested cadence,
not round(30/fps), which would turn both 16 and 18 fps into 15 fps. Temporal shader
noise uses integer presentation-frame seeds; freezes animate Print grain.

## Shared analysis and quality

Build shared Vision person segmentation, guided mask refinement, Gaussian and
bilateral blur, deterministic grain, Oklab palettes and time-based EMA. Palette
analysis uses 64×36 samples, six deterministic k-means iterations, previous
centroids, lightness sorting, updates every six frames and a 0.5 s EMA. Oklab
ΔE 25 means 0.25 in its normalized coordinates. Scene cuts reset temporal state.
Masks use balanced live quality and accurate editor analysis; a recording's saved
analysis is authoritative for reproducing its live look. Different Vision
quality levels are not falsely presented as bit-identical. Cache by source,
algorithm version and parameters; seeking cannot change an export's result.

Color Isolation and Chroma Key have a versioned temporal-matte implementation.
Legacy recipes retain their spatial rendering.
Their coefficients are **per source frame**, whereas palettes and Auto Background
use time-based smoothing. Interpret a two-frame EMA using the conventional
period rule, current weight `2 / (2 + 1)`. Keyed alpha uses prior weight 0.25;
reduce that weight smoothly to zero as perceptual-luma motion rises from 0.01
to 0.02, avoiding a noisy binary threshold. Use a finite source-indexed window
whose omitted-history bound is below 0.001 (eight and six frames respectively).
Initialize with the oldest included matte. A source gap over 250 ms, an internal
scene cut or the effect's starting frame closes the history; a mid-frame effect
start uses the frame already displayed. Animated parameters do not reset it.
At higher source rates the time span decreases, while per-frame weights stay
unchanged. The pure window mathematics and stateless GPU window kernels are implemented
and tested. A bounded GPU cache and recursive, source-indexed history provider
now connect version-2 recipes to the compositor and palette/frame sampling.
Historical mattes include the complete upstream effect prefix; duplicate effects,
animated parameters, mid-frame starts and random seeks are covered by native
tests. History warming is cancellable. Current raw mattes are reused when their
evaluation is equivalent, including an effect's own intensity animation.
Live capture now uses bounded rings and records accepted-frame times and reset
decisions in the analysis sidecar. New Color Isolation and Chroma Key recipes
now default to version 2 after the sustained physical checks. Existing saved
recipes retain their original algorithm version.

Render determinism is checked on linear half-float pixels and the YCbCr frames
submitted to the encoder. Four independent exports produce identical hashes for
all 120 frames of the temporal fixture. Apple's hardware H.264 compression can
produce slightly different decoded pixels from identical input; compressed-file
comparisons use PSNR > 40 dB. Byte-identical compressed files are not guaranteed.
Core Image uploads share the effect command queue; pooled outputs are retained
until the destination render explicitly completes.

Pop palettes contain sixteen original colors in JSON, selected dark-to-light;
user palettes can be sampled, locked, resampled and saved. B&W thresholds use
histogram quantiles, never hard-coded equal bands. Face detail uses a shared
person mask when available, an eight-pixel local contrast radius at 1080p.

Background assets: local Photos image/video, original procedural scenes, solid
colors and Blur original. Save Fit/Fill, framing, blur and exposure; video decode
uses a bounded queue, repeats the last decoded image when late, crossfades loop
ends, and defaults to muted. Optional background audio is −18 dB. Match color
uses conservative subject exposure/white-balance matching.

## UX and validation gates

The recorder remains full-screen. A single effects entry opens a compact drawer;
active looks are clear and individually bypassable. The editor uses Tools →
Video effects with the existing selection scope, preview, Apply/Cancel, persistent
Undo/Redo, and retappable timeline markers. Picking an individual effect opens
its controls. A help button gives access to its film history.
Keyframes have explicit add/remove/previous/next actions and a visible playhead.
Depth-only options explain missing depth and do not silently pretend to run.

Check parameter bounds/serialization, effect order, crop/trim/split/archive
preservation, keyframes, repeatability and no-op intensity. Compare golden GPU
frames and two independent renders. Use synthetic fixtures plus authorized local
footage; no copyrighted reference clips are downloaded. Skin hue tests cover
three tones (≤8° drift). Key matte tests cover mixed pixels, wrinkles and holdouts.
Measure static-shot stability and 30-second sustained recording, CPU/GPU/memory,
thermals, selected effect combinations and fallbacks on the 14. 17 verification
is separate; an unavailable 15 Pro cannot be claimed tested. Decode/frame equality
is distinguished from container bytes, which include changing export metadata.

## Licensing and references

New implementations and built-in palettes/backgrounds are original MIT code/data.
Only Apple frameworks supply segmentation/tracking. No new model weights or
third-party algorithm implementation is imported. CorridorKey is excluded; its
[primary license](https://raw.githubusercontent.com/nikopueringer/CorridorKey/main/LICENSE)
retains non-commercial/share-alike and additional integration restrictions.
Historical notes are short original summaries, supported by the source index
maintained with the catalogue. App name and icon are excluded from the code license.

Apple APIs: [person segmentation](https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest),
[depth capture](https://developer.apple.com/videos/play/wwdc2022/110429/).
Technique sources already checked: [Eastman dye transfer](https://www.eastman.org/technicolor/2b-dye-transfer-printing-images),
[BFI silent colour programme](https://www.independentcinemaoffice.org.uk/films/the-wonderful-world-of-colour/).

## Delivery checkpoints

1. Versioned catalogue, parameters/keyframes, original palettes, math tests.
2. Shared Metal renderer/utilities, palette analysis and deterministic image effects.
3. Editor preview, timeline integration, assets and complete effect controls.
4. Temporal editing, segmentation/keying, backgrounds and camera tracking.
5. Live recorder integration, analysis persistence, thermal/budget paths.
6. Golden/temporal/device and UX review loops, documentation, installation.

Each checkpoint is committed after its checks. This list is a work plan, not a
claim that any unimplemented capability has shipped.

Duo adaptation reference: https://developer.apple.com/iphone-duo/prepare/ .
Size from view geometry, preserve recording orientation separately from layout,
and test resizing/folding without discarding editor or capture state.

## Night fix (editor restoration)

Night fix restores dark source footage before the creative effect chain. It is
in Color & style and supports selected ranges, persistent edits and keyframes.
Its Intensity, Shadow brightness (up to +8 stops), Noise reduction (up to 300%)
and Preserve detail controls are shared by all three modes: Fast (default,
no temporal preparation), Medium (three aligned frames), and Precise (nine).
Temporal modes reuse separate full-resolution fusion caches. Effect-inspector
playback and scrubbing stay inside the selected range, including comparisons.
See [Night fix implementation and workflow](NIGHT-FIX.md).

### Kaleidoscope

In **Camera & frame**, choose **Kaleidoscope** and select 2 through 9 divisions.
Two keeps the half clockwise from the starting ray and reflects it across one
line. With the default vertical line, the right half supplies the image. Higher
counts divide a full turn into equal sectors. Even counts alternate reflections.
Odd counts repeat the full source sector by rotation, giving three 120° images
or nine 40° images. Sampling reflects at the picture edges.

While editing, drag the center handle to move the split, turn the round handle
to rotate it, or drag a detail anywhere else to pan the source. Twist two
fingers on the picture to rotate the source around the split center. The
detail at the center stays fixed as the rest of the image turns in each wedge.
**Fine adjustments → Source rotation** sets the same angle in degrees. The gesture
keeps the role and sector it had at touch-down, even across a seam. The cyan
arc identifies the source wedge. Closing the inspector hides the guides.
Fine adjustments and editor keyframes are available for each parameter.
Live preview and export share the same Metal map, including for downstream masks.

The historical note refers to the mirror camera in [Kaleidoscope Shop (1959)](https://www.eamesoffice.com/the-work/kaleidoscope-shop/).

### RGB Offset

Under **Color & style**, drag one of the three labeled crosshairs to translate
that color channel. The others keep their positions. All three start at the
center. Double-tap a pad to recenter it. Its outer ring corresponds to 12% of
the shorter image dimension, so the displacement scales with resolution. Each
pad supports VoiceOver movement actions. Animate in the editor to keyframe
both axes; Intensity blends the registered and offset images.

The historical note refers to aligning the three matrices in
[dye-transfer printing](https://www.eastman.org/technicolor/technology/dye-transfer-printing).

### Negative Strobe

Under **Time**, choose the number of positive/negative cycles per second.
At 15 cycles/s on 30 fps material, every other frame is a color negative.
The negative is calculated in display values so middle gray stays near middle
gray. Rate changes preserve phase. A rate above half the rendering frame rate
is limited to one polarity change per frame.

In the editor the strobe starts positive and covers the selected range.
Enable **Limit duration** for a 0.10–10 second burst at its beginning. A
shorter selection ends the effect earlier. The clock is set in playback
seconds when applied, follows the underlying edit, and continues across clips
in the original selection. Seeking backward returns the same polarity.
Intensity blends the negative into the original during the negative frames.

On camera, **Try strobe** auditions one burst (two seconds when duration is
unlimited). Starting a take starts a fresh cycle. Camera defaults to a
one-second burst. The guides and audition controls are preview-only.

The historical note draws on the
[Harvard Film Archive’s program on experimental flicker films](https://harvardfilmarchive.org/calendar/paul-sharits-program-2015-09/1).
