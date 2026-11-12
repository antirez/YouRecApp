# Camera changes: acceptance and delivery

The October 27 landscape-selfie regression exposed a gap in our process. The
simulator fixture supplied an already-wide synthetic buffer. Its passing test
proved the viewport fit that buffer, but bypassed the sensor configuration that
was failing. An earlier physical probe aborted; its configuration fix was then
installed without a successful replacement probe. Calling out that limitation
was accurate, but did not deliver the requested working camera feature.

## Required evidence

For a change to camera framing, orientation, encoding, or capture format:

1. Reproduce on the affected physical camera before changing the implementation.
   Archive the current project manifests and recorder preferences first. Use an
   isolated diagnostics directory and never write test footage into user projects.
2. Trace the entire path: active format, dynamic dimensions, actual delivered
   pixel-buffer dimensions, connection rotation/mirroring, preview transform,
   writer canvas, and saved file dimensions/transform. Requested settings and
   successful API callbacks are not substitutes for actual output.
3. Compare an identifiable scene in the real on-screen preview and saved movie.
   Include objects at left, right, top and bottom and something with an obvious
   upright orientation. Look for missing edges, pillarboxing inside letterboxing,
   stretched shapes, and rotated or mirrored text. A 16:9 file alone proves none
   of these properties.
4. Exercise the public control, not only direct diagnostic setters. Check idle,
   active recording, stop/restart and leaving the mode. Cover supported 1080p/4K,
   SDR/HDR, mirroring and effects-on/off paths relevant to the change. Inspect
   preview stability and capture timing during the expensive combination.
5. Keep simulator tests for layout, gestures and lifecycle. Include recorded
   input geometry from the failure when feasible; do not replace hardware
   acceptance with a synthetic ideal input. Model-level assertions must fail on
   the old implementation before they count as regression coverage.
6. After the last relevant code change, rerun the affected physical checks.
   Restore recorder preferences, install in place, and verify existing projects.
   Preserve reports, screenshots, source-frame samples and commit IDs together.

## Device artifact cleanup

- Never use `devicectl device copy to --remove-existing-content` against an
  appDataContainer. On 31 October, passing a test subdirectory as the destination
  still removed the broader app data. An empty-source copy is not a safe delete.
- Remove archived test files only through the debug cleanup harness, with exact
  validated names under its own namespace. Never allow `Projects` or
  `RecentlyDeleted` in that manifest.
- Before any device cleanup, keep a complete backup of user projects (source
  media, manifests/history and export records), not just an inventory. Compare
  the user inventory immediately afterward, before launching the app or running
  further diagnostics. A cleanup error requires inspection, not an assumption
  that only the intended directory was removed.

If the device is locked or unavailable, continue independent work. Mark the
camera feature as awaiting hardware acceptance. Do not describe it as fixed or
ready based on compilation, a simulator pass, or an unverified configuration
change. A crash or failed framing check keeps that acceptance gate open.

## Review discipline

Keep the hypothesis, observed evidence, and remaining uncertainty separate in
progress reports. Reviewers must receive the full user requirement; long terminal
prompts should reference a local task file rather than rely on a pasted prompt
that may be truncated. Review advice must be checked against the user's explicit
behavior before being implemented. Record which findings were acted on and which
were rejected with the reason.
