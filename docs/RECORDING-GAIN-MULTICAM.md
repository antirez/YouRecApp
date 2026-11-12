# Recording gain and two-camera layouts

31 October 2026. Implementation specification for the recording screen.

## 1. Adjustable recording level

- Tap the existing microphone/level pill to open a compact recording-audio panel. It contains the microphone selector, the live meter, a Recording gain slider and Reset to 0 dB. Closing the panel immediately returns the space to the preview.
- Gain is adjustable while idle, recording or paused. No segment restart, audio interruption or time shift is permitted. The change affects newly recorded sound only.
- Range: −40 to +12 dB, in repeatable 0.5 dB steps; default 0 dB. Reset means unity gain, including after previously selecting an overloaded level.
- Store the chosen gain per microphone identity. Reconnecting an input restores its setting. A fallback input uses its own setting; the existing microphone-disconnect warning remains.
- Apply gain to copied PCM before encoding, with a short sample-rate-independent 20 ms ramp. Preserve stereo balance and timestamps. Do not mutate microphone-owned buffers.
- The live meter displays the signal actually being recorded, after gain. Show clipping in red, without a blocking alert. Lowering gain must clear overload feedback promptly. Do not add an automatic limiter or alter the audio enhancement chain.
- Long-press help explains recording gain and that it cannot repair sound already distorted at the microphone.

## 2. Two-camera recording

### Entry and capture

- Open Camera settings beside Effects to switch on **Use two cameras** and choose the First and Second cameras. The same panel contains recording color and a **More settings** row for the full recorder settings. The lower camera selector lists single-camera lenses and changes to Swap and Layout in two-camera mode.
- First and Second describe the displayed slots (background/inset, left/right, or top/bottom), including Swap. Offer only compatible partners in Second. Changing First keeps Second when supported; otherwise choose a supported partner. Keep all touch targets at least 44 points and keep the top bar within the portrait viewport.
- Single-camera recording retains its existing behavior, camera-specific zoom/focus memories and quality settings.
- Default pair: rear main plus front camera. Offer only camera pairs reported as simultaneously usable by the device; two rear cameras are permitted when supported. Names use the existing lens labels. Never show the same physical camera in both slots.
- Select the camera pair before recording or after finishing the take. During an active or paused take, camera selection is locked with an explanation; composition controls remain available. Swapping their displayed positions does not reconfigure either camera.
- First implementation: 1080p, 30 fps, SDR for two-camera recording. Show this explicitly in the mode controls. Preserve the user's single-camera 4K/HDR preferences and restore those when leaving Two cameras. When resuming an existing paused take, its established output canvas is retained and the 1080p composition is fitted to it. Reject an unsupported configuration with an actionable explanation and restore single-camera preview.
- Record one composed movie and one continuous microphone track. The preview composition is the recorded composition. Layout changes are baked into the new footage; this version does not retain two separate raw camera recordings for later reframing.
- Keep the full output frame visible in two-camera mode. Both portrait and landscape output are supported. Freeze output orientation and dimensions from Record through Pause/Resume, as for an ordinary take.
- Two-camera preview follows **Mirror selfie preview**, on by default, for front-camera pictures only. **Save mirrored selfies** independently controls their saved orientation. Never flip the whole split or move the inset when mirroring. Compose preview and recording separately when needed, including when the front camera fills the canvas behind a rear-camera inset. Preview gestures follow the displayed mirror direction.

### Camera assistance

- Camera settings contains independent **Stabilize**, **Level horizon**, and **Follow face** icon toggles, labelled and highlighted when enabled. Long press explains each. Each preference is remembered and initially off.
- Stabilize uses Apple's capture stabilization on each supported feed before composition. Prefer low-latency stabilization, otherwise Standard; never select cinematic/auto modes implicitly. Show the actual active support in the menu, including partial or unavailable support. Choose before recording or while paused, with the resulting crop already visible in the preview.
- **Level horizon** corrects rear-camera roll before effects and two-camera composition. Gravity supplies the level reference. A long, near-horizontal edge can refine it after several agreeing observations. When the camera points straight up or down, correction eases toward neutral. Front-camera panes and layout dividers keep their orientation.
- **More settings → Level horizon → Max angle** previews the actual framing while adjusting the limit from 0.5° to 10° in half-degree steps. The default is 9°. A fixed crop reserves room for the entire selected angle. At 16:9 this gives 1.09× framing at 3°, 1.27× at the default 9°, and 1.29× at 10°. Both preview and recording use this crop. Change either setting before a take or while paused.
- Synchronize both video outputs by capture timestamps before composition, so different stabilization delivery delays cannot pair unrelated moments. Preserve the capture timestamps for audio alignment.
- Follow face uses Vision face detection independently on the stabilized feeds. Initially prefer a prominent face near the center and retain it through brief losses. Smoothly pan within existing overscan with a central tolerance; preserve zoom, aspect ratio and the layout. No added zoom or empty borders. When the face is lost, hold the framing; reacquire smoothly.
- Face following can change during a take. Deliberate manual picture panning disables it, while pinch zoom and moving/resizing the inset do not. Detection runs on a separate bounded worker at reduced resolution; late results never block recording and obsolete results are ignored after mode changes.
- Tracking uses face location, not audio speaker identification. A partial face at the sensor edge remains eligible; movement stops at the available crop boundary. The UI reads the current tracked framing at gesture start rather than publishing camera movement into open menus.

### Layouts and manipulation

1. **Floating**: camera A fills the canvas; camera B starts in a square inset. Drag to position it. A pinch aligned within approximately 23° of horizontal changes width; near vertical changes height; a diagonal pinch resizes proportionally. Lock this choice at gesture start. Keep the complete inset inside the canvas and remember its position, size and aspect ratio. Aspect fill crops each feed without stretching it or introducing empty bands. A Swap button exchanges the feeds without moving/resizing the inset.
2. **Side by side**: a vertical divider separates the left and right feeds. Start at 50/50. Drag the divider horizontally to allocate 15–85% of the frame to either feed.
3. **Top and bottom**: a horizontal divider separates the top and bottom feeds. Start at 50/50. Drag the divider vertically over the same 15–85% range.
4. **Diagonal**: two upright, aspect-filled feeds occupy complementary triangles. The default line joins top-right to bottom-left canvas corners. Tap the central 44-point handle to flip to top-left/bottom-right and back; dragging never translates the line. Two-finger pan/zoom acts only on the touched triangle, including with the Layout panel closed. Face following aims inside the upper/lower triangle using existing crop room.

Floating offers **Rectangle / Circle** controls. Circle stays round in either orientation; all pinch directions resize it proportionally. Drag moves the inset, constrained inside the output. Returning to Rectangle retains its rectangular aspect. Both shapes use the same composition for preview and saved footage, respecting the independent selfie-mirroring preferences. The circular rim is antialiased without transparent holes; touches outside it pass to the underlying picture.

- Use literal labels and small layout icons; avoid the ambiguous labels “vertical split” and “horizontal split” in isolation.
- The Swap button beside Layout exchanges the two camera feeds on each tap, while recording as well as idle. Recording continues through the swap with uninterrupted video and audio.
- A Layout button reveals compact controls and an editing overlay. An obvious Done control hides the handles; the composition remains active. Visible divider handles have at least a 44-point touch target even though the rendered separator is thin.
- Each split feed fills its region without stretching. Use two fingers within either split picture to pan its crop and pinch to zoom, also with the Layout panel closed. Both gestures work simultaneously. Divider dragging has priority only in its handle hit area. Floating-mode inset dragging moves the inset; its camera crop starts centered.
- Keep separate divider values for side-by-side and top-and-bottom. Switching layouts preserves camera order and inset geometry.
- Layout edits do not conflict with recording, Stop, Pause, Mark, microphone, or layout controls. Handles and control backgrounds are UI only, never encoded. Keep the existing placement of capture buttons away from the physical camera end of the phone.

### Other recording behavior

- Use the existing microphone selection, route fallback, gain, project append/new-project, bookmark, pause/resume and crash recovery behavior.
- First-version two-camera capture uses autofocus and composition pan/zoom. Physical lens zoom and manual focus controls remain in Single camera, with their per-camera settings preserved.
- Ordinary color/background/texture effects operate on the composed image and retain the existing preview/export pipeline. Physical single-camera Dolly/Crash Zoom controls are unavailable in two-camera mode; retain their saved single-camera choices and explain the limitation in the effects UI.
- Choose supported multi-camera formats and check the session hardware cost before starting. Bound retained frames and GPU work; never let a missing secondary camera produce an unbounded frame queue. Reuse the most recent secondary frame briefly; if delivery stalls, clearly report/pause rather than silently record a frozen second camera indefinitely.
- Session interruption/runtime failure saves the current recording through the existing finalization path. Exiting Two cameras releases both camera inputs before restarting the ordinary session. Do not silently fall back to a different camera pair mid-take.

## Internal representation

- A small Codable layout value stores mode, swap, inset rectangle, two divider positions and per-feed pan/zoom. Pure geometry functions are shared by preview interaction and the compositor.
- A dedicated AVCaptureMultiCamSession owns two video outputs with explicit connections. The existing single-camera session remains separate. Share the existing microphone engine and segment writer; convert both camera timestamps to the existing host clock.
- Composite into a bounded pixel-buffer pool using Core Image/Metal. Share crop/layout between the recorded and displayed frames while applying their independent front-mirror preferences before compositing. Reuse the recorded buffer when mirroring is identical. Run live effects after composition: keep preview and recording analysis separate so recorded masks/palettes describe the actual saved image. Clean-plate capture stores a paired recording reference, and recording recipes use that reference. Both render paths use the same recording clock.
- Gain runs on the media queue; capture topology runs on the capture queue; SwiftUI receives observable state on main. Layout updates are immutable snapshots passed to the media queue.
- Mode/pair changes are transactional: stop the old capture source, configure and validate the replacement, and recover the prior usable source on failure. Discard callbacks from inactive or obsolete outputs, and reject stale geometry during orientation changes.

## Acceptance

- Unit tests: layout bounds, divider limits, aspect-correct fill, pan/zoom, swap, Codable round trip; PCM gain/peak/20 ms ramps, unity/reset, stereo, sample counts and timestamps.
- Public UI tests: open microphone panel, change/reset recording gain during a take; select every layout, drag divider, resize/reposition inset, swap, close/reopen controls, rotate idle and preserve framing while recording/paused.
- Physical iPhone 14: inspect both live feeds and saved movies for Floating, Side by side and Top and bottom; swap/drag during recording; audio continuity, frame timing, Stop/Pause/Resume, leave/re-enter mode, and return to single-camera 1080p/4K/SDR/HDR and live effects as applicable.
- Physical iPhone 17 Pro: confirm supported pairs and front-sensor geometry; preserve the working single-camera Front ultrawide portrait/landscape modes.
- Follow docs/CAMERA-QA.md: back up manifests/preferences before diagnostics; use isolated test footage; retain actual screen captures, saved-frame samples, metrics and final revision. A successful build or simulator fixture is not hardware acceptance.
- Install in place and compare project inventories/manifests/preferences. Restore preferences changed by diagnostics.

## Platform references

Apple's AVCaptureMultiCamSession uses inputPriority and requires manual active-format selection: https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession
Supported capture formats: https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/ismulticamsupported
Hardware budgeting and permitted device combinations: https://developer.apple.com/videos/play/wwdc2019/249/
