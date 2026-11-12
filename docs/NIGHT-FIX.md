# Night fix

Implemented 28 October 2026, after the user selected the algorithmic restoration
from the low-light comparison.

## Controls and workflow

Editor → Tools → Video effects → Color & style → **Night fix**. It follows the
existing selected-clip/range scope, is removable, and participates in persistent
Undo/Redo. It is not offered in the recorder.

- **Mode**: **Fast** (default) uses single-frame spatial/chroma cleanup, with no
  temporal preparation or fusion cache. **Medium** combines three motion-aligned
  frames using guides up to 256 px and medium flow accuracy. **Precise** combines
  nine frames with guides up to 512 px and high flow accuracy. This choice is
  constant for the effect, saved with it, and used for both preview and export.
- **Intensity**, 0–100%, defaults to 100%: mix the restoration with the source.
- **Shadow brightness**, 0–8 stops, defaults to +2.5: fixed exposure with a
  white-preserving shoulder. There is no frame-dependent auto-exposure pumping.
- **Noise reduction**, 0–300%, defaults to 100%: controls cleanup strength; Medium/Precise also blend temporal
  restoration with the source. Above 100% increases spatial/chroma cleanup.
- **Preserve detail**, 0–100%, defaults to 50%: retains more local texture at the
  expense of residual noise. All four controls support existing keyframes.

The default brightness matches the comparison's exposure setting; the native
implementation uses Apple's classical flow and original Metal filtering, so it
is not pixel-identical to the OpenCV desktop prototype. Very high settings are
intentionally available for extremely dark footage. They reveal compression and
color artifacts and soften detail; they cannot recreate information never captured.
The inline explanation appears below the sliders so adjusting a value cannot
push the control away from the finger. Original/Effects provides comparison.

Fast's immediate preview is its final result: Apply and export do not schedule a
hidden, more expensive pass. In Medium/Precise, a quick, explicitly labeled
spatial preview appears while full-resolution restoration prepares. Completed
source chunks are reused for slider changes, with separate caches for each mode.
The accurate preview replaces the quick preview while paused. Apply stores the
edit immediately; preparation can continue in the main editor. Export waits for
complete restoration at the chosen mode. Cancelling preparation leaves completed
reusable chunks, discards partial files, and leaves source media/edit timing/audio intact.

Video-effects and audio-tool previews play only the selected range, including
Original/Bypass comparisons and replay. Video-effects scrubbing is bounded to
that range and displays elapsed/total range time. Internal project/source time
remains absolute so keyframes, transitions and overlapping tracks stay aligned.
The preview bounds follow speed/hold edits, and reopening a subrange effect uses
its own region. Crop and the other tool inspectors already isolate their scope;
transition previews retain their adjacent-shot context.

## Restoration and integration

`VideoEffects/NightFix.swift` and the `nf_*` Metal kernels implement the original
algorithm; there are no new third-party libraries or model weights.

1. Read actual source presentation timestamps, including variable-frame-rate
   input. Medium restores each frame using one neighbor on either side; Precise
   uses up to four on either side. Fast skips steps 1–5 entirely.
2. Build reduced-resolution, pre-smoothed, square-root luma guides (at most 512 px
   on the long side). Vision optical flow explicitly uses **revision 1**, the
   classical algorithm. Serialize Vision requests; do not select the neural revision.
3. Reject exposure/scene changes. Weight aligned observations by forward/backward
   flow consistency, photometric agreement and temporal distance. Occlusion,
   unreliable motion and frame boundaries fall back to the current frame.
4. Average in linear light using the explicit BT.709 OETF inverse, with half-float
   GPU accumulation. Keep the incoming video's code-value interpretation through
   an extended CoreMedia 709 color space; a display-profile conversion before
   decoding would alter near-black brightness relative to the reference.
5. Cache fusion before adjustable spatial cleanup, brightness, chroma cleanup and
   final intensity mixing. Main10 HEVC is explicitly required (10-bit input alone
   does not force a 10-bit encoder). Reversible square-root packing of encoded
   channels preserves small shadow differences before later strong brightening.
6. Adaptive local Wiener shrinkage, white-preserving exposure, separable
   luminance-guided chroma filtering and intensity mixing use the same kernels
   for editor preview and export. Highlight values above reference white remain
   above white; later creative effects retain their existing HDR mapping rules.

Night fix runs on the source before crop, stabilization transforms, LUTs,
background processing, grading and overlays. It also feeds palette/matte-prefix
analysis. Each clip's original source clock resolves the restoration cache,
including split clips, overlap transitions, speed changes and Freeze Frame.
The cache never contains or replaces audio.

## Cache, interruption and resource policy

Each chunk contains at most 60 real source frames plus temporal read context.
Cache identity includes source SHA-256, algorithm version, processing mode, source HDR status,
Vision revision and OS version. JSON records source timestamps, count and byte
size. Missing/truncated chunks regenerate. Publication is atomic; incomplete
UUID-named working movies are removed on cancellation or first use after a crash.

Instructions lease all requested cache files before awaiting work, so another
preparation cannot evict frames in use. A soft 4 GB per-project limit evicts old,
unpinned chunks; an active large project may exceed that limit. Caches are excluded
from backup and can be regenerated. Minimum free-space checks report an actionable
error. This is not a promise of unlimited-length processing on a nearly full phone.

Deferred preview work yields when inactive or thermally constrained; export takes
priority. Night preparation keeps the display awake. Per-job wake identifiers
prevent a cancelled old job from releasing a newer job's wake request.
