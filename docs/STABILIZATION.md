# Editor stabilization

Requested on 23 October 2026. Stabilization is an offline, nondestructive edit.
Open **Tools → Stabilize** from the editor toolbar. A marked range takes
precedence over a selected clip; with neither selected, the tool applies to the
whole project. The workspace header identifies the scope. Tap a stabilization
chip beside the timeline to edit or remove the entire existing effect.

The dedicated workspace preserves a large, aspect-fit video preview. Portrait
places settings underneath; landscape uses a narrow, scrollable side panel.
Choose Off, Light, Standard or Strong, play/scrub the selected footage, and compare
Before and After using the controls pinned just below the image. Comparison
preserves the source position while rebuilding the preview. This workspace plays source audio;
the main editor's independent original/processed audio selection is preserved.

Analysis has progress, permits original playback, and can be cancelled by leaving
the workspace. After analysis, changing a level reuses the motion measurements.
Apply saves one undoable edit; Cancel changes nothing. An unchanged state does
not create an undo entry. The chosen level
survives project reopening and ZIP transfer. A timeline badge identifies stabilized
clips. Export applies stabilization regardless of which before/after view was
last selected.

## Algorithm decision

Use two-pass, feature-based 2D stabilization: spatially distributed Shi–Tomasi
corners, pyramidal Lucas–Kanade tracking with a forward/backward consistency test,
RANSAC similarity estimation, then temporal camera-path smoothing. Edge features
receive additional weight to reduce the influence of a moving foreground face.
The implementation is native C++/Swift with AVFoundation and Accelerate; it adds
no third-party library or model weights.

This follows the established keypoint/optical-flow/global-motion approach
described in [OpenCV's stabilization documentation](https://docs.opencv.org/4.12.0/d4/d2c/group__videostab__motion.html).
The tracker follows the multiscale method in
[Bouguet's Lucas–Kanade reference](https://web.stanford.edu/class/cs231m/references/pyr-lucas-kanade-feature-tracker-bouget.pdf).
Those are algorithm references, not vendored implementations.

Gaussian local-linear regression of the camera path in reference coordinates preserves constant-speed pans,
including the ends of a clip. A stronger setting uses a longer smoothing window.
Motion estimation includes scale for robust fitting, but correction applies only
translation and rotation: recorded zooms keep their original timing. Smoothing
the inverse motion path prevents a zoom after a completed pan from introducing
false sideways drift. The crop
factor is fixed across the analyzed reference range, preventing zoom breathing.
An exact inverse-corner check bounds the crop; a smooth anticipation envelope
reduces correction locally around a large bump. One outlier does not weaken an
entire take. Unreliable tracks start a new segment, and correction fades out/in
over 0.3 seconds around those boundaries.

| Level | Smoothing sigma | Maximum crop zoom |
| --- | --- | --- |
| Off | None | 1.000× |
| Light | 0.12 s | 1.045× |
| Standard | 0.28 s | 1.100× |
| Strong | 0.50 s | 1.180× |

The UI shows the actual zoom, which can be smaller than the cap. Stronger settings
trade some framing for smoother motion. There is no spatial mesh deformation;
faces and straight lines retain their shape.

Considered alternatives: L1 path optimization can produce cinematic constant,
linear and parabolic camera paths, but adds a constrained optimizer and tuning
burden for this first mobile implementation. See
[Grundmann et al., CVPR 2011](https://research.google.com/pubs/archive/37041.pdf).
Projective/mesh stabilization can address more complex motion but risks visible
deformation and needs considerably more validation for close-up people. Gyro-based
stabilization needs synchronized motion/lens data that our imported videos and
existing recordings do not supply. Apple's image registration APIs can estimate
alignment, but a direct sparse tracker provides explicit outlier rejection and
spatial weighting for this application.

## Timing, persistence and recovery

Decode luma frames, downsample to a maximum dimension of 640, and retain every
source frame's presentation timestamp. At each point on the editor's 30 fps output
grid, rendering uses the correction for the actual held source frame. This avoids
inventing intermediate camera positions when a 24/25/60 fps source is resampled.
Encoded-frame coordinates are
corrected before orientation and canvas fitting. Audio is not shifted or retimed.

Each saved clip setting contains its original analyzed reference range. Splits,
trims within that range, reorder and ripple deletion inherit that range and sample
the same path at their new source offsets. Adjacent split pieces keep exactly the
same crop. Extending a trim beyond the original range requires fresh analysis of
the expanded range. Analysis caches are fingerprinted and versioned, excluded from
backup/portable archives, and safely rebuilt from originals when absent. Cached
trajectory storage is bounded per project; LRU memory caches hold up to three
analyses and sixteen plans, each also capped at 360,000 aggregate samples (except
when a single active reference is itself larger). Choosing Off retains the analyzed
reference for re-enabling later. Independently stabilized clips have independent
framing; cropping a previously stabilized take retains its original crop reference.
Interrupted analysis currently restarts, while completed analysis remains reusable.

## Verification and limits

Native tests exercise subpixel motion estimation, outlier rejection, blank frames,
scene changes, preservation of pans/zoom, monotonically stronger smoothing on a
known path, and source inclusion at corners between analyzed frames. Media tests
cover analysis reuse after splitting, real decoding/export, source integrity,
audio and video duration, export receipts, portrait rotation metadata, variable
frame rate, 24/25/60 fps imports, and internal cuts. Simulator tests exercise comparison, playback,
level changes, Apply/Cancel/Undo, and accessibility text in landscape. A screenshot
pixel check verifies that paused comparison actually redraws the video.

Very blurry/dark/textureless footage can fail to track. Dominant moving foregrounds
and substantial parallax remain difficult; use the comparison to choose a suitable
level. This implementation does not repair motion blur or rolling-shutter wobble.
Broad selfie, walking and low-light field validation remains necessary.
