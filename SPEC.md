# YouRec product specification draft

YouRec is an iPhone app for creators who want to record a video over multiple
sessions, make precise cuts using the audio waveform, improve speech audio, and
export without losing their original footage or editing history.

This specification expands the requirements supplied on 22 October 2026. The
implementation contains an early capture/editor prototype; see [README.md](README.md)
for verified behavior and remaining work. **Confirmed** items come from the user;
**Proposed** behavior supplies defaults for review. **Open** items require a
product decision or a device experiment before their behavior can be promised.

## Confirmed scope

- Pause and resume recording, including after Stop, closing the app, and returning
  days later. New footage belongs to the same project.
- Change cameras during recording. Support every built-in front and rear video
  camera available on each supported iPhone, including iPhone 17 Pro front-camera
  landscape capture. This is not a commitment to support every historical iPhone.
- Offer quick zoom presets and a duration in seconds for moving to the selected
  zoom. Each individual camera has its own independently remembered zoom value;
  changing one camera's zoom must not change any other camera's saved value.
- Show the active microphone and its signal level over the recording interface.
  Offer quick selection and a persistent microphone preference order.
- Support fixed focus: lock the current focus, return to autofocus, and offer
  manual lens-position control on cameras that support it.
- Automatically choose the highest-priority available microphone outside
  recording. Do not upgrade microphones automatically during recording.
- If the recording microphone disconnects, automatically select a fallback and
  show a visible warning. This is an explicit exception to the previous rule.
- Provide separate recording and editing interfaces, with simple CapCut-like
  cutting and an aligned audio waveform beneath the video timeline.
- Provide an open-weight AI voice-isolation filter and an AI filter intended to
  produce a studio-microphone sound. Use open weights for both filters and run
  them offline on the iPhone. Allow multiple AI and EQ stages in an ordered,
  repeatable, independently bypassable chain.
- Export to a new media file. Preserve sources and store edits in a project.
  Undo and redo survive closing and reopening that project.
- Provide video stabilization in the editor, with user-selectable strength and
  excellent preview/comparison UX. This is an offline edit, including imported
  footage, rather than a dependency on camera stabilization during recording.
- Carry out a substantial, extended UI/UX study. The app must be exceptionally
  usable on the go and have an attractive, organized, coherent visual design.
  Both interaction quality and visual quality are core product requirements.

## Recorder layout — confirmed correction

The camera preview must occupy the full screen. Place a minimal set of controls
on the image. Do not shrink footage into a card or place a persistent settings
form, app header, or navigation bar around it. Secondary options belong in a
sheet or another deliberate disclosure. Preserve legibility on bright/complex
footage and keep the subject unobscured. The first form-like engineering UI was
rejected on the device and is not a design reference.

## UI and UX study and design requirements

**Confirmed:** allocate a long, dedicated research and design phase before
committing to the production interface. A quick visual pass or a polished static
mockup is insufficient. Repeated prototype iterations and use on an actual phone
must inform the design. Technical experiments can proceed while this work is
underway, but the demo layout is not the approved production design.

The central use case is a creator recording on the go, with limited attention,
often holding the phone in one hand. A person should immediately understand
whether recording is active, which camera and microphone are in use, what frame
will be saved, and whether an intervention is needed. The editor must make precise
cuts possible on a small screen without making routine edits feel technical.

The study must cover these areas:

| Area | Required investigation and deliverable |
| --- | --- |
| Real recording situations | Map handheld selfie recording, rear-camera footage, a mounted phone, outdoor light, noisy locations, interruptions, and switching between recording and review |
| Existing workflows | Study successful capture and cut-editing interactions, including the CapCut reference; document useful patterns and friction rather than copying a whole interface |
| Information architecture | Define Recorder, Projects, and Editor navigation, continuation after Stop, clear task boundaries, and discoverable advanced controls |
| Thumb reach and interaction | Test alternative control arrangements in portrait and landscape, left- and right-handed use, accidental touches, grip changes, and large tap areas |
| Recording states | Design idle, recording, paused, saving, interrupted, mic fallback, unavailable camera, and low-storage states; make active recording unambiguous without relying on color alone |
| Front-camera framing | Prototype landscape video inside a portrait phone UI, preview mirroring, crop boundaries, zoom, and control placement without obscuring the subject |
| Precision editing | Test waveform legibility, scrubbing, timeline zoom, selection handles, cut audition, undo/redo, and recovery from mistaken edits |
| Visual direction | Explore multiple coherent directions for typography, spacing, contrast, color, iconography, motion, and component hierarchy, then refine one across the entire app |
| Accessibility and environment | Validate sunlight readability, reduced motion, larger text, screen-reader labels, touch-target sizes, and feedback when sound cannot be heard |
| Field validation | Use interactive prototypes and the app on real phones, observe task completion, collect feedback, and repeat until the agreed usability targets are met |

**Proposed interaction goals:** Record, Pause, Resume, and Stop each require one
deliberate action from the recording screen. Camera and zoom presets remain
directly accessible. Microphone selection takes at most opening the selector and
choosing an input. Advanced options use progressive disclosure while essential
state stays visible. Final control placement must come from testing these goals,
not from fitting every option onto the preview.

**Proposed visual principles:** make live footage the visual focus; use clear
grouping, restrained and consistent color, legible type, balanced spacing, and
recognizable controls. Give recording and urgent warnings distinct emphasis.
Motion should explain state changes without delaying input or hiding feedback.
An attractive dark camera interface is a direction to explore, not a substitute
for testing contrast outdoors. Avoid decorative clutter and ambiguous icon-only
controls. Evaluate haptic and audible feedback for their effect on captured audio.

The study produces a task map, navigation and state flows, several layout and
visual alternatives, interactive prototypes, reusable component rules, findings
from observed use, and a prioritized list of problems and revisions. Both recorder
and editor must be represented; polishing the recorder alone does not satisfy
the requirement.

**Acceptance:** a first-time user can start, pause, continue a stopped project,
switch camera, select a zoom transition, identify the active mic and its fallback,
cut a sentence using the waveform, undo that cut, and export without instruction
or losing source footage. Repeat key capture tasks one-handed and in outdoor
light. Review aesthetics across normal, empty, loading, and error states as well
as the ideal screen. Set task-time, error-rate, and discoverability targets before
the validation round; keep unresolved usability problems visible.

**Open:** study duration and budget, participant coverage, visual references and
brand direction, preferred handedness defaults, numeric usability targets, and
which features need accessibility alternatives. These details do not reduce the
confirmed requirement for an extended study and an excellent final experience.

## Project and media model

**Proposed:** the project is the durable unit of work. A recording consists of
ordered source segments; an editable timeline refers to ranges of those sources.
A rendered export is a separate artifact. A single imported video can also be
the sole source of a project.

| Object | Meaning and retention |
| --- | --- |
| Project | Name, identity, recording settings, media references, timeline, edit history, and export records |
| Source segment | Immutable recorded or imported media; never rewritten by an edit |
| Timeline clip | A selected range of a source placed in the current edited sequence |
| Audio derivative | Processed audio tied to its source, model version, and parameters |
| Export | A new playable video produced from a fixed project revision |

This lets Stop finalize captured media without preventing later continuation.
Appending footage need not rewrite a large existing video. The editor presents
one continuous timeline regardless of internal recording segment boundaries.

Proposed storage is an app-owned project directory, with a versioned manifest,
media, edit history, and replaceable thumbnail/waveform caches. Use stable media
IDs and relative references, rather than relying on filenames or absolute paths.
Keep time as integer values plus a timescale to avoid cumulative rounding errors.

Imports should copy media into managed storage by default so that deleting a
Photos item does not unexpectedly break a project. Exporting a portable project
must include its media and history; sharing a rendered video alone does not.
Import support and portable project sharing remain scope decisions.

## Recording and project lifecycle

**Proposed behavior:**

| Action | Result |
| --- | --- |
| Record in a new project | Begin capturing synchronized video and audio |
| Pause | Finalize the current source segment; remain in the recorder with preview available |
| Resume from Pause | Start the next segment; omit the paused wall-clock interval from the video |
| Stop | Finalize capture, save the project, and release capture resources when leaving the recorder |
| Continue recording | Reopen an existing project and append new footage, even after an app restart |
| New recording | Create a separate project explicitly |
| Edit | Open the separate editor after pending media has been finalized |

Show captured duration separately from edited duration when cuts make them
different. Paused time does not count toward either. Returning from a phone call,
backgrounding, or a system interruption must never start recording without a new
user action. Preserve completed segments and show the reason recording stopped.
Apple exposes explicit capture-interruption reasons, including background camera
unavailability and system pressure. [Apple capture interruptions](https://developer.apple.com/documentation/avfoundation/avcapturesession/interruptionreason/videodevicenotavailableinbackground)

When an already edited project is continued, the proposed default is to append
new clips to the end of its current timeline and preserve earlier edits. Original
capture order remains in the source inventory. **Confirmed 24 October:** recording
additions are outside editor Undo. Add each new segment to every editing baseline,
including redo states, so earlier editing operations remain reversible after
continuing a recording. Removing a take is an explicit editor action and remains
undoable.

**Open:** whether continuation should instead add footage to a source bin for
manual insertion; whether Stop should open the editor or project overview; and
the maximum recording length and acceptable recovery loss after a crash.

**Acceptance:** record A, pause, record B, stop, close the app, reopen later, and
record C. One project contains A+B+C without paused intervals or duplicated
frames at joins. Previously completed edits still apply. Audio remains aligned
across the complete exported sequence.

## Camera support and switching

Discover cameras and supported formats at runtime. Offer direct access to rear
ultrawide, main, and telephoto cameras where present, plus available front camera
modes. Deduplicate alternative API representations of the same hardware so users
do not see misleading extra lenses. Depth and LiDAR sensors are not additional
ordinary video cameras.

**Proposed:** distinguish a physical lens choice from an Auto camera choice that
lets the system manage a virtual camera. A requested physical lens must not be
silently represented as selected while another lens supplies the picture. In
Auto mode, report the actual active lens where the platform exposes it.

A switch during recording remains part of the current project and take. Preserve
the microphone selection and the audio timeline, restore the destination camera's
zoom, and record a camera-change marker. The preview must match the recorded
framing. If the switch fails, retain the previous usable camera and show a clear
error; do not leave the recording indicator active with no valid capture.

**Confirmed:** a brief switch delay is acceptable. Hold the last visible frame
over the preview until the destination camera is rendering, instead of showing
black. Preserve the audio timeline and hold the previous recorded video frame
through the gap. Perfect real-time switching and concurrent camera capture are
not requirements. Routine switching holds must not interrupt recording with a
large warning banner; retain their timing as editor events. Unexpected capture
failures still need clear feedback.

**Confirmed:** place an icon-only front/back switch immediately left of the
camera-name menu. It selects the most recently selected usable camera on the
opposite side, or the first available camera on that side if none was selected.
Keep the menu for explicit lens selection and retain each camera's own zoom and
focus settings. Prevent repeated switch requests while a switch is in progress.

**Open:** exposure and white-balance behavior during transitions. A seamless
switch at every resolution and frame rate is not a verified capability.

### Front camera landscape capture

**Confirmed:** support the iPhone 17 Pro front camera's landscape mode.
**Working interpretation:** record an upright landscape image while the phone
is held in portrait, using the camera's available wide framing. Ordinary
landscape capture with the phone rotated must also work.

Apple exposes the Center Stage camera as a front ultrawide device, with dynamic
aspect ratios on supported formats. Changing those dimensions during recording
requires ending the current movie segment; a video-data pipeline can start a
new segment at the reported change time. [Apple Center Stage recording guidance](https://developer.apple.com/videos/play/wwdc2026/341/)

The installed SDK declares dynamic-aspect-ratio support from iOS 26. Check OS and
format capabilities instead of using a model-name whitelist. A format with no
supported dynamic aspect ratios needs the conventional capture path. [Apple format capabilities](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/supporteddynamicaspectratios)

**Proposed:** choose the project output shape before recording and keep it fixed
through a take. Treat device orientation, capture crop, preview layout, and export
orientation separately. A landscape project shows its exact landscape frame even
inside a portrait phone UI. Record front-camera video unmirrored by default, with
a separately configurable mirrored preview. Automatic face tracking and automatic
zoom are separate, optional features; they must not override explicit framing.

**Open:** allow output-shape changes between segments of one project, and how to
fit mixed portrait/landscape footage if that is allowed. The proposed first
version uses one project canvas and does not change it during capture.

**Acceptance:** on an iPhone 17 Pro held upright, capture a landscape front-camera
clip. Preview, editor, and export agree on framing, orientation, and mirroring.
Then switch to each available rear camera and back, retaining the project shape
and correct zoom. Also test both landscape device orientations and a conventional
front camera on an older supported device.

## Zoom controls and memory

**Confirmed:** zoom memory is per individual camera. Rear main, rear ultrawide,
each rear telephoto, and front cameras retain independent values. A shared global
zoom or a single value for all rear cameras does not satisfy this requirement.
Changing camera B must not overwrite camera A's saved zoom. Switching back to A
restores A's own value, including after an app restart.

Provide large preset buttons for valid zoom levels, current zoom feedback, and a
separate transition-duration selector. Presets reflect the actual camera and
active format; they must not advertise unavailable optical magnifications.
On the rear ultrawide, the **1× Main** preset switches to the physical main
camera at its native framing. The other presets adjust the selected lens.
Opening a lens from the camera list restores its remembered zoom.

**Confirmed gestures:** tapping a zoom preset uses the saved transition duration;
double-tapping it reaches that target in one second without changing the saved
duration, including when it is set to Instant. Distinguish the two gestures before
starting a transition, so the first tap cannot trigger an instant jump.

The duration stays visible at the left of the zoom presets, including at zero.
Swipe up to increase it or down to decrease it, with half-second steps, a visible
vertical adjustment indicator, and haptic feedback. The implemented range is
0–30 seconds; Settings offers common presets and shows the current custom value.
VoiceOver exposes duration adjustment and a separate one-second zoom action.
The chosen duration means time to reach the new zoom, rather than a speed that
produces different durations for different distances. An instant transition
uses zero seconds. Ignore a request for the already active zoom.

**Confirmed:** zoom motion must slow before stopping. Interpolate log magnification
with a quintic ease-in/ease-out curve, whose speed and acceleration reach zero at
the endpoints. Drive the curve by elapsed time so dropped callbacks do not extend
the selected duration. Apply the exact target at completion; handle Instant and
equal zooms separately. Hardware and visual validation remain necessary.

A new preset request supersedes an ongoing transition and starts from the actual
current zoom. Switching cameras cancels the old transition; it must not resume
unexpectedly when that camera is selected again.

**Proposed:** persist the last applied zoom, keyed by stable camera identity,
across launches. Keep physical lens profiles distinct from virtual Auto profiles.
Clamp restored zoom only when a new active format cannot represent it, and show
the applied value. Keep the saved preference so a temporary format restriction
does not erase it. Use a consistent user-facing zoom reference; internal device
zoom values are not
necessarily the labels familiar from Apple's Camera app.

Interrupted ramps remember the last applied zoom, not an unreached target.
**Open:** hardware timing tolerance and whether front portrait/landscape framing
should have separate remembered zooms. Separate memory per framing mode remains
proposed.

**Acceptance:** start a 1x-to-2x transition, interrupt it with another target, and
observe no initial jump. Set different supported zoom values on the rear main,
rear ultrawide, rear telephoto, and front cameras. Change just one, switch through
all cameras, then relaunch the app: every camera restores its own value and the
others are unchanged. Repeat at supported range limits and with a temporary
format restriction. The interrupted-ramp expectation follows the chosen policy
above; independent camera memory is mandatory under either policy.

## Fixed focus

**Confirmed:** fixed focus is available before and during recording. Provide an
explicit focus lock that holds the current lens position without hunting, a
visible locked indicator, and a deliberate return to autofocus. Locking focus
must not also lock exposure unless the user separately requests that behavior.

**Proposed:** provide a near-to-far manual slider where supported. Remember mode
and lens position independently for each camera and restore them on returning to
that camera. Never apply another lens's saved position. Unsupported cameras show
their fixed-focus status or explain which adjustment is unavailable. A preview
tap must not unexpectedly release a lock.

Do not label normalized lens positions as meters or calibrated infinity. Apple's
values do not represent the same physical distance across devices.
[Apple lens-position semantics](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition)

**Acceptance:** lock on a subject, move foreground/background objects through
the frame, and confirm no refocusing in the saved video. Adjust manual focus
while recording without stopping capture; switch cameras and restore each
camera's own setting. Verify unsupported hardware and return to autofocus.

A long press on the focus control toggles red focus peaking in the preview,
gives a haptic, and briefly displays its on/off state. Fixed-focus lenses also
offer peaking. A tap on a lens that supports choosing an AF point places the
focus box where the camera was asked to focus.

**Open:** whether manual controls need a magnified focusing view.

## Microphone selection and monitoring

Show the actual active microphone name, live input-level meter, and clipping
indicator over the preview. The meter measures incoming audio before optional
editor effects. Distinguish valid silence from an unavailable input or stalled
audio stream. Proposed meter behavior is channel-aware peaks in dBFS, refreshed
around 20 times per second with a short peak hold.

The quick selector lists inputs currently offered by iOS. A separate list lets
the user reorder remembered preferences, including temporarily disconnected
devices. Identify hardware using stable identifiers when available; identical
display names must not silently merge different devices. Availability means
selectable as an input, not merely paired or remembered by Bluetooth.

Selecting an input is a request to the audio session. Confirm the effective input
from the current route before updating the UI or claiming success. [Apple input selection](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinput(_:))

| Situation | Required or proposed result |
| --- | --- |
| Idle in Auto mode | Use the highest-priority selectable input |
| Better microphone connects while recording | Keep the active microphone |
| Active microphone disappears while recording | Try remaining inputs in preference order, warn visibly, and mark the event |
| Lost microphone reconnects while recording | Keep the fallback until the take stops or the user selects another mic |
| Camera changes | Preserve the selected audio route; verify it did not change |
| User selects another mic | Proposed: allow it, verify the result, and mark any interruption |
| No valid microphone remains | Open; proposed: pause capture and require an explicit decision to continue without audio |

Manual selection is proposed to override Auto for the current recording session
without rewriting the preference order. Pause retains the selected input if
available. Stop ends that override; continuing a stopped project resolves the
preference order again and displays the new selection before recording.

For fallback, show the former and replacement microphone, keep a visible notice
until acknowledged, and keep a timeline marker afterward. Store the detected
route-change time and any known missing-audio interval. Preserve valid video and
make an audio gap explicit rather than claiming a seamless transition. iOS itself
can reroute audio when devices are added or removed, so the app must observe and
verify system-driven changes as well as its own requests. [Apple route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)

**Proposed:** the microphone overlay appears only in the app UI, not burned into
exported video. Keep the most direct available recorded input; document any
unavoidable device or OS processing. Bluetooth, USB receivers, built-in inputs,
and multichannel interfaces need separate validation; equal audio quality is not
assumed. Normalize to the project's audio timebase while retaining source format
metadata and compensating measured latency.

**Open:** hardware to support initially, mono/stereo and dual-transmitter handling,
manual switching during takes, input-gain controls, headphone monitoring, and
behavior if every fallback fails. An app cannot identify which wireless lavalier
is active behind a receiver that exposes only a single unnamed input.

**Acceptance:** prefer mic A over B. Record with B and connect A: B remains active.
Start another take using A, unplug it, and verify B becomes active with a warning,
correct meter, and persisted event marker. Reconnect A: no automatic upgrade.

## Separate recording and editing interfaces

Provide three clear destinations: Recorder, Projects, and Editor. Recorder keeps
camera, zoom, microphone, pause, and stop controls immediately accessible. The
project library offers Continue recording, Edit, and exported versions. Opening
the editor releases capture resources once pending media is safe.

**Proposed first editor:** one ordered video track with linked source audio,
thumbnail timeline, and an audio waveform directly below it. They share the
same time scale, scroll position, selection, and playhead.

Support scrubbing, timeline zoom, frame stepping, trim handles, split at playhead,
range selection, delete selection with automatic gap closure, clip reordering,
and undo/redo. Keep audio and video linked through these operations. A user
gesture, such as dragging a trim handle, produces one undo step.

Show a visibly labeled Clear action after marking Start and after completing a
Start/End range. Clearing removes the selection and exits cut audition without
deleting footage or adding an undo/redo step.

Generate multiresolution waveforms asynchronously and cache them, so opening a
long recording does not require decoding all audio into memory. Show an explicit
loading state. The waveform should make quiet intervals easy to find without
assuming every low-amplitude sound is disposable silence.

**Proposed:** display the source waveform by default, with an optional processed
waveform once AI audio is available. Silence snapping or low-energy highlights
may assist cuts, but automatic silence removal is a separate scope decision.
Audition around a proposed cut before committing. Use short, non-time-shifting
audio fades where needed to avoid clicks; make their effect consistent in preview
and export.

**Open:** whether imports, clip reordering, multiple tracks, music, captions,
transitions, speed changes, and reframing belong in the first release. The phrase
"CapCut-like" establishes an interaction reference, not that app's entire feature
set. Proposed first scope includes trimming, splitting, deletion and reordering;
the other tools remain outside the initial cut editor.

**Acceptance:** remove a mistaken sentence by selecting the quiet regions around
it. Playback and export remove the same interval, preserve synchronization, and
have no unintended gap. Undo restores the original selection and its audio.

## Offline AI audio filters

**Confirmed:** users can add multiple AI filters and EQ stages, chain them in a
chosen order, reorder them, and bypass or remove individual stages. Repeated
instances of an effect are allowed. Each instance has independent parameters.
Save the entire ordered chain in the project and its persistent undo/redo history.
The confirmed control design is a horizontally ordered row of colored vertical
effect columns. Each has a separate on/off control above it and a filled body
that adjusts its principal parameter. Tap a column to select it and show its
specific settings below; tapping must not change its value. Hold the header grip
to reorder. Horizontal body swipes scroll longer chains, and relative vertical
drags adjust values, with one persistent undo operation per completed gesture.
In landscape, the selected settings may sit beside the columns to preserve usable
fader height and keep controls out of the system gesture area.
Selection and bypass must remain visually distinct. Include units, short readable
names, model/EQ-frequency identity, and alternatives to drag-only actions.
Preview and export must apply the same chain. Show unavailable models explicitly;
never silently skip an enabled effect. The initial default is project-wide;
per-clip overrides are a later proposed extension.

Both filters process recorded audio in the editor and run entirely on the iPhone.
Do not upload audio, use a server fallback, or require an online API for inference.
Keep the original audio and make each effect independently bypassable.

### Voice isolation

Reduce unwanted background sound while preserving intelligible speech and the
speaker's characteristics. Provide an amount control, an audition range, and
level-matched original/processed comparison. A value of zero must return original
audio, without model-induced delay or coloration.

Listening-level matching uses energy windows audible in both versions. Exclude
near-silence (below −60 dBFS RMS) and heavily suppressed windows (over 20 dB
reduction), then apply the relative energy gate to both versions. If no shared
audible reference remains, use unity gain on both previews: Original must not be
turned down to match denoised silence. This is an energy-based comparison, not a
claim of speech detection. Export gain is unchanged.

**Open:** whether isolation means removing non-speech noise, reducing room echo,
or also removing other people speaking. A speech denoiser does not by definition
isolate one chosen speaker. Multiple intended speakers, singing, music, wind,
clipped recordings, and very quiet speech need explicit quality expectations.

DeepFilterNet3 is now an optional bundled 48 kHz voice-isolation model, alongside
RNNoise. Its pinned Core ML streaming conversion runs offline on the iPhone;
model choice and amount are undoable project settings. Runtime checks and
on-device measurements are recorded in the audio experiments. Listening quality
and room-echo removal remain open. [DeepFilterNet project](https://github.com/Rikorose/DeepFilterNet)

### Studio voice enhancement

Improve perceived clarity, body, and tonal balance while preserving the spoken
words, voice identity, timing, and lip synchronization. Provide amount and bypass
controls separately from isolation.

**Proposed interpretation:** a natural studio-voice effect, rather than a promise
to reproduce a named microphone exactly. Equalization, compression, de-essing,
and limiting can complement the AI stage, but do not fulfill the requested AI
effect by themselves. Generative restoration must be tested for altered words,
breaths, consonants, and voice coloration.

Resemble Enhance is a candidate to compare for denoising and speech restoration.
Its published implementation does not establish acceptable iPhone runtime, memory
use, or an exact microphone-emulation capability. [Resemble Enhance project](https://github.com/resemble-ai/resemble-enhance)

**Open:** a reference for the desired sound, model choice, and acceptable
artifacts. Both filters should be selected from models with open weights.

### Initial model shortlist

The following shortlist was checked against upstream sources on 22 October 2026.
The prototype now bundles RNNoise, DeepFilterNet3, and a Core ML conversion of LavaSR v2. All three
run offline on the iPhone 14 Pro Max: a 20-second RNNoise pass measured 0.585 s,
a first LavaSR pass 2.083 s, and a warm isolation/restoration/EQ chain 1.788 s,
with unchanged sample counts. These are runtime measurements, not proof of
listening quality or room-echo removal. DeepFilterNet3’s 20-second pass measured 0.593 s; its full 17-minute
stereo isolation/restoration/EQ chain took 77.620 s and about 102 MB. The
remaining candidates are comparison work.

| Candidate | Published capability | Proposed role in YouRec |
| --- | --- | --- |
| [DeepFilterNet3](https://github.com/Rikorose/DeepFilterNet) | Full-band 48 kHz speech denoising, released pretrained models; repository code is MIT or Apache-2.0 | Optional integrated noise-removal model; pinned weights/DSP/graph and CPU backend, persistent model choice |
| [RNNoise](https://github.com/xiph/rnnoise) | C noise-suppression library with distributed models and 48 kHz processing; repository is BSD-3-Clause | A native integration and efficiency baseline against which to judge more complex denoisers |
| [LavaSR v2](https://huggingface.co/YatharthS/LavaSR) | Bandwidth restoration to 48 kHz; upstream reports approximately 50 MB of PyTorch weights and Apache-2.0 for model and code | A compact candidate for restoring muffled or bandwidth-limited speech; test whether it helps actual phone recordings |
| [Resemble Enhance](https://huggingface.co/ResembleAI/resemble-enhance) | Denoiser and speech-restoration/enhancement modules trained at 44.1 kHz; official weights are marked MIT | A comparison for the studio-voice effect; measure conversion effort, processing time, and memory before selection |
| [GTCRN](https://github.com/Xiaobin-Rong/gtcrn) | Ultra-lightweight speech enhancement with released checkpoints; upstream inference uses 16 kHz | Optional efficiency reference; do not discard the bandwidth of clean 48 kHz recordings merely to use it |

LavaSR's reported model size is not its working memory requirement, and its
published speed figures are not iPhone benchmarks. Its upstream describes
bandwidth extension and an optional denoiser, not calibrated imitation of a
particular studio microphone. [LavaSR implementation](https://github.com/ysharma3501/LavaSR)

**Proposed evaluation order:** compare DeepFilterNet3 with RNNoise for natural
noise removal; compare LavaSR v2 with Resemble Enhance for restoration. Test the
enhancers independently and after denoising rather than assuming that stacking
models improves quality. Clean, already full-band input must be part of the test
set. Keep restoration optional when it adds artifacts or no audible benefit.

For the studio-voice control, evaluate a restoration model plus restrained tonal
shaping, compression, de-essing, and limiting. This is a proposed audio chain;
the desired sound still needs a reference. None of the selected capabilities
establishes exact emulation of a named microphone or reliable recovery of the
original missing frequencies.

NVIDIA's RE-USE models are additional research comparisons, but their official
cards specify the NVIDIA One-Way Noncommercial License. They are therefore not
the proposed default for a commercially distributable app. [RE-USE](https://huggingface.co/nvidia/RE-USE), [Real-time RE-USE](https://huggingface.co/nvidia/Real-time_RE-USE)

Compare level-matched English and Italian speech from the actual target
microphones, with clean audio, fan/street noise, wind, room echo, and overlapping
speech. Measure changes to words and voice identity, lip synchronization,
processing time, peak memory, and thermal behavior. Select a shipping model only
after validating its exact weight artifact, dependencies, and license notices.

### Processing and reproducibility

Suggested starting order is isolation, studio enhancement, then optional final
level adjustment; the user can change the order and add EQ anywhere. Process source
ranges with enough neighboring context for the model, then trim to the requested
range; do not join unrelated sentences before providing model context.

Processing must be cancellable, report progress, and use bounded memory. Retain
completed chunks when interrupted where the model permits safe resumption.
Compensate model delay and resampling so processed audio has the same timeline
duration. Prevent clicks at chunk and edit boundaries. Suspend heavy processing
when entering Recorder.

Store model identity, weights checksum, runtime version, parameters, effect
order, and any stochastic seed with the project. Retain the active processed
audio when exact regeneration is not guaranteed. Updating a model must not
silently change an existing edit. Missing older models should allow original
playback and show the effect as unavailable rather than substituting a new model.

Before adopting a model, verify the exact code and weight licenses, device
conversion/runtime support, memory use, processing time per minute, thermal
behavior, and quality on English and Italian speech. These are implementation
gates, not reasons to replace the offline requirement with a hosted service.

**Open:** minimum supported iPhone for AI, processing-time and memory budgets,
whether weights ship in the app or are downloaded once, and handling of stereo
or multiple speakers. After required weights are present, all filters must work
in airplane mode. Whether first launch must also work without a model download
still needs a decision.

**Acceptance:** process representative speech in airplane mode; compare original
and processed audio at matched loudness. Verify unchanged words and timing,
absence of chunk-boundary artifacts, bounded memory on a long recording, and
repeatable reopened-project playback. Model selection requires measured results.

## Export and persistent editing history

Every export creates a new file with a distinct identity. Never overwrite a
source, an earlier export, or the project as a side effect of rendering. Use a
temporary output and publish it as complete only after success. Cancellation,
low disk space, or a failed export must leave existing media usable.

Render from a fixed project revision so later edits cannot partially affect an
export in progress. Record that revision and export settings. Rendering does not
replace the editable timeline with the rendered file or clear undo history.

**Implemented export:** MP4 at 30 fps with AAC audio, retaining the project canvas.
SDR timelines use H.264/Rec.709; timelines containing HDR use HEVC/10-bit HLG.
Files sharing and Save to Photos are available. Log and other advanced export
profiles remain outside the implemented scope.
Do not promise frame-accurate arbitrary cuts without re-encoding when the source
format requires it. Preview and final render must use the same edit timing,
orientation, crop, and audio-effect settings.

Undo/redo history includes trim, split, delete, reorder, explicitly inserted timeline clips,
and effect or output-setting changes. Save the operation history, current history
position, and enough prior state to reverse operations. Saving only the current
timeline is insufficient. Checkpointing may accelerate reopen without truncating
the retained history.

**Proposed history semantics:** ordinary linear undo/redo. Closing and reopening
preserves both undo and redo, including closing after an undo. Making a new edit
after undo replaces that abandoned redo path; preserving alternative branches is
a separate feature. Do not impose a silent history-depth limit while a project
exists. If storage compaction would destroy undoable states, make that an explicit
user decision.

Recording adds footage to all retained edit states without advancing the undo
cursor or discarding redo. Undo must never remove a newly captured segment. Older
documents migrate only exact first full-source append transitions; other edits
and intentional deletions are retained. Missing timeline references alone do not
authorize restoring unused sources. Recover those only by explicit user choice.

**Acceptance:** record two segments, edit, undo all, then make a new edit: both
recordings remain. After editing A/B/C, undo twice, record more footage, and redo:
the edits and the added footage both survive. Explicit deletion and its undo still
work. These guarantees survive reopening and project archive restoration.

Retain every original in the project's source inventory, including sources absent
from the current timeline and all retained history. Undoing an edit
must not fail because background cleanup deleted its source. Deleting an entire
project is a separate destructive library action with its own retention policy;
it is not an ordinary editor undo operation. Missing or corrupt media should be
reported and relinkable without rewriting the remaining project.

**Acceptance:** make edits A, B, and C; undo C; close; reopen; redo C. Then undo C
and make D: conventional redo of C is no longer offered. Export twice: both new
files exist, source hashes are unchanged, and editing history remains available.

## Reliability and capture defaults

Proposed initial capture profiles are 1080p30 and 4K30 SDR; offer additional frame
rates only after validating them. Choose a compatible profile for the cameras the
user intends to switch between. All cameras must be usable in some supported
profile; this does not imply every lens supports every profile. Explain a
combination restriction before recording and offer a compatible profile rather
than silently changing quality during a take.

The current starter targets iOS 17. Keeping that baseline while gating newer
camera features is proposed; a final supported-device/OS matrix is still needed.

Persist completed media and project transactions incrementally. Recover the last
consistent project revision after interruption. Use finalized or recoverable
media chunks so a crash does not invalidate an entire long take. Define and
measure the maximum loss window instead of claiming zero loss of in-flight data.

Handle denied or revoked permissions, insufficient storage, battery and thermal
pressure, calls, lock/background transitions, and audio/camera device failures.
Warn before storage is exhausted and reserve space to finalize pending media.
Do not silently lower quality or delete sources to make room. Keep the screen
awake while recording; background recording is not a proposed first-version
feature.

Proposed timing target is audio/video alignment within one project video frame,
including joins and exports. Camera and microphone discontinuities must be
measured and separately identified, rather than hidden by that target. A
60-minute recording/edit/export test on the target phone is a proposed baseline,
not an established maximum duration or measured performance result.

## Decisions still needed

| Decision | Proposed starting point | Why it matters |
| --- | --- | --- |
| UI/UX study plan and visual direction | Extended research, multiple prototypes, and repeated phone/field testing before production UI | On-the-go usability and visual quality are core requirements |
| Supported phones and OS versions | iOS 17 baseline; iOS 26 camera feature gates | Hardware tests and AI performance cannot be inferred from OS compatibility |
| Capture profiles | Implemented 1080p30/4K30, HDR/SDR before recording or paused; runtime compatibility | Quality, storage, heat, and switch availability |
| Camera-switch continuity | Hard cut, preserve audio; measure video gap before choosing a tolerance | May determine whether concurrent capture is necessary |
| Project aspect ratio | Fixed 16:9 or 9:16 chosen before capture | Avoids unexpected crops and dimension changes during recording |
| Resume after existing edits | Append new clips to the edited timeline | Alternative is adding to a bin for manual insertion |
| Zoom details | Last applied value; separate front-framing memory; preset durations above | Interrupted ramps and camera modes otherwise have ambiguous behavior |
| Mic override and complete audio loss | Manual override lasts until Stop; pause if no fallback exists | Completes the confirmed fallback policy |
| Audio hardware and tracks | Define actual microphones; support one selected input first | Stereo, dual lavaliers, gain, and latency vary |
| Voice isolation meaning | Suppress non-speech background noise first | Selecting one speaker is a different requirement |
| Studio voice target | Natural enhancement with a supplied before/after reference | Needed to select and evaluate a model |
| AI device and resource budgets | Benchmark iPhone 17 Pro first; choose numeric limits afterward | Offline feasibility and acceptable wait time |
| Weight delivery | Open weights for both; decide bundled versus one-time download | App size and fresh-install offline behavior |
| Editing scope | One linked video/audio track, cuts and reorder | Keeps the first editor bounded |
| Undo branches | Persist linear undo/redo; replace redo on a divergent edit | Distinguishes durable history from a branching version system |
| Media ownership and portability | Managed originals; separate video export and project archive | Prevents broken projects and unexpected deletion |
| Focus persistence | Fixed focus is required; propose independent per-camera mode and lens-position memory | A lens position is not a calibrated distance and cannot be copied across cameras |
| Exposure and capture stabilization | Automatic exposure/white balance; preview and recording mirroring are independently configurable. [Editor stabilization](docs/STABILIZATION.md) is separately confirmed and implemented. | Directly affects recording usability and camera transitions |
| Export quality and destinations | Implemented SDR/HDR MP4, Files and Photos; further profiles remain open | Must match YouTube use without guessing advanced format needs |
| Recovery and performance limits | Set loss window and interaction targets after device experiments | Makes reliability claims testable |

## Proposed implementation sequence

1. **Conduct the extended UI/UX study.** Research real creator workflows, explore
   visual and interaction alternatives, prototype the complete recording/editing
   flow, and test repeatedly on actual phones. Agree usability and visual-quality
   criteria before committing to production screens. Continue validation through
   the later stages; this is a substantial workstream, not a final styling task.
2. **Prove hardware and AI feasibility.** Enumerate every camera on the target
   phone, verify front landscape framing, measure camera transitions and mic
   fallback, and benchmark candidate audio models. Resolve any hardware conflict
   before committing to a capture pipeline or AI promise.
3. **Build durable capture.** Implement project storage, actual video/audio
   recording, pause/resume, Stop/continue across launches, source preservation,
   interruption handling, and a basic joined export.
4. **Add recording controls.** Implement camera switching, zoom transitions and
   memory, microphone ranking, real metering, and visible fallback events.
5. **Build the cut editor.** Add waveform and thumbnails, linked cuts and trims,
   persistent undo/redo, preview, and revision-based export.
6. **Integrate offline audio effects.** Add the selected models, audition and
   bypass, bounded processing, cache/version behavior, and export integration.
7. **Validate complete sessions.** Exercise long takes, all camera modes,
   microphone disconnects, storage pressure, relaunch recovery, repeated exports,
   and reopenable history on the supported device matrix.

These stages are an implementation order, not a reduction of the confirmed
feature set. Completion requires the accepted behaviors above and explicit
resolution of the relevant open decisions.


### Current document validation bounds

Source durations and total edited duration are limited to seven days in schemas 1 and 2. This prevents invalid or hostile document values from overflowing sample/time conversions; it is not a tested continuous-capture duration. Individual capture testing currently covers one hour.

## Editor Tools revision — 24 October 2026

The editor toolbar replaces the standalone Stabilize action with **Tools**.
The panel offers Stabilize, Text, Color LUTs, Pauses and Speed, with a visible
scope summary and a list of existing effects. Marked Start/End range takes
priority over a selected clip; with neither, tools affect the whole project.
New Text defaults to three seconds at the playhead unless a range is marked.
Each workspace has Cancel/Apply and makes one persistent undoable edit. Cancel
never changes the project. Timeline effect spans are tinted; 44-point effect
chips in the timeline status row reopen their settings, including Remove.
Thumbnail taps continue to select/deselect clips normally. Existing effects are
also reachable through Tools → In this project.

- **Listen:** plays one second either side of its starting playhead and returns
  there. Preview cut also returns to its starting position. Repeated Listen,
  frame steps and Original/Processed comparison retain that anchor; scrubbing or
  entering a tool explicitly ends the audition.
- **Stabilize:** Off/Light/Standard/Strong, current selection or whole project,
  comparison, analysis progress, actual crop zoom and weak-tracking feedback.
  Applying only to a section may change framing at its edges.
- **Text:** frozen preview in the final project's canvas, editable text (up to
  500 characters), four tap-cycled styles, six colours, drag positioning, pinch
  resizing and accessible position/size controls. Start/end controls and 2/3/5 s
  presets set timing. The exact CoreText rasterizer is shared by placement and
  export. Text follows source footage through edits: Speed and Pauses change its
  visible duration. Reordered, separated text fragments are edited individually
  for duration; style-only edits preserve the fragment's source timing.
  When re-editing text, duration controls stay within its associated clips.
- **Color LUTs:** authored 33³ SDR creative LUTs (Natural, Warm, Cool, Cinema,
  Mono), strength and Before/After. Natural removes the look. External .cube
  import and camera-specific Log transforms are not included in this revision.
- **Pauses** detects gaps in original audio using the louder channel’s 10 ms RMS
  level. By default it estimates a silence threshold per recording from room tone
  and stronger passages. Detection settings also offer one manual dBFS RMS
  threshold, a minimum pause duration, and independent padding after and before
  speech. Existing peak-based edits retain their saved cuts and manual peak level.
  Review starts with the removal summary, Previous/Next, explicit Cut/Keep and
  Listen. Navigation seeks in the current scoped preview. Listen auditions the
  join in After, or the entire pause in Before/Keep, then restores the starting
  position. Before/After retains the same source moment. Detection settings are
  collapsed initially; threshold/minimum changes rescan automatically after a
  short debounce. Raw candidates and Keep choices persist; temporary settings
  that hide a candidate retain its Keep decision within the open draft. Padding
  changes do not rescan. No-candidate drafts cannot create an empty effect.
  Fully quiet recordings remain reviewable, retaining at least one frame;
  missing audio and padding-swallowed cuts have distinct explanations. Pause removal is an editable source-domain
  exclusion, not a destructive ripple deletion; Remove restores those pauses
  while retaining other edits. New footage exposed by extending a trim is not
  automatically scanned: Detect again includes it. Clips with no audio are
  left unchanged. No claim of speech recognition or noise-aware detection.
- **Speed:** 0.25×–4× with slider and quick presets. Audio pitch is retained using
  AVFoundation's spectral time-pitch algorithm for preview and export. Slow
  motion repeats available source frames; no generated intermediate frames.

Effects shared across split clips retain one identity. Reopening Speed, Color,
Stabilize or Pauses edits all remaining pieces of that effect; applying a new
selected-range effect gives that range a separate identity. All tool data is
included in project history, portable archives and export receipts. Source media
is never overwritten. Pause candidates/cuts are pruned to each split piece to
avoid duplicating whole-take metadata in every history revision.

Text and grading use one Core Image compositor, applying stabilization before
canvas fitting, colour before text, and a tagged Rec.709 output. The editor and
export use the same pipeline. A source with audio extending beyond its video
renders a black video tail with any active text, rather than failing the export.

## Preview inspection and Crop — 24 October 2026

- The main editor preview supports temporary pinch zoom from 1× fitted view to
  8×, with one-finger panning bounded by the picture. It cannot shrink below 1×.
  A top-right 48-point reset icon is visible only while enlarged. Playback
  continues. Inspection changes neither project history nor exported pixels.
  A player-item/layout-size change resets inspection; accessible zoom/reset
  actions are available.
- Tools → Crop follows marked-range / selected-clip / whole-project scope.
  A fixed output-shaped window identifies the retained picture, with dimmed
  context outside. Pinch and pan, or visible zoom/position sliders, change the
  draft without rebuilding video for each gesture. Reset framing centres and
  fills; Preview plays the actual result with text and other video effects.
- Framing uses normalized centre coordinates and 1×–8× zoom relative to filling
  the output window, on the stabilized upright source. It is a static reframe,
  with hard transitions at selection boundaries, and never changes timing/audio.
- Video shape applies to the whole project. By default it follows the first take
  while any of its picture remains on the timeline, even after insertion, splitting
  or reordering. Removing its last picture makes the first remaining video set the
  upright dimensions. Detached audio does not determine the shape. Undo and Redo
  restore the framing along with the edit.
- In Crop, selecting 16:9, 9:16, 1:1 or 4:5 fixes the format even when the selected
  ratio already matches the frame. Presets keep the short-side resolution. A
  committed crop also fixes the canvas. Choosing Original with no crop returns
  to automatic sizing. Reordering after a fixed choice preserves it. Uncropped
  clips remain aspect-fit, with bars as needed; text stays in output coordinates.
- Apply stores shape and crop as one persistent undo step. Cancel stores nothing.
  An unchanged full-frame crop creates no history entry or range splits, including
  when imported source dimensions need rounding to even output pixels.
  Shared crop IDs survive splits and reopen all related pieces. Remove crop
  keeps the committed output shape. All crop/output fields are optional so older
  documents decode unchanged. The source media is never modified.
- Timeline thumbnails remain source images with a coloured lower effect line;
  Crop has an editable chip. Export displays the pinned output dimensions.
- Original / Processed audio controls have a microphone icon on their left.



## Capture and editing revision — approved 24 October 2026

1. **Mirroring at capture.** Front preview is mirrored by default; the saved video
   is unmirrored by default. Independent persistent settings control preview and
   recording. Rear cameras retain normal orientation. Saving orientation is fixed
   for a take. The frozen switch preview follows the visible preview preference.
2. **Mirror tool.** Independent horizontal/vertical flips apply to a selected range,
   selected clip, or the whole timeline. Mirror the footage after crop/stabilization;
   preserve readable Text/Image overlays. Reopen/remove through timeline effects.
3. **Cut and Paste.** Cut the selected range or clip into a project-scoped clipboard.
   Paste inserts at the playhead and ripples later footage. The auxiliary selection
   row exposes Cut/Delete/Clear and subsequently Paste. Keep the clipboard when
   navigating away and back in the same app session. Cut/Paste are separate undoable
   edits. Preserve source ranges, pauses, speed, crop and effects; pasted effect IDs
   are independent from the original. Preserve exact non-frame-grid clip boundaries.
4. **Review speed.** A bottom-left preview capsule opens horizontal 1/1.5/2/2.5/3×
   choices. Preserve audio pitch. It affects playback only; Listen/cut audition
   remain at normal speed. Review speed returns to 1× when the editor is reopened.
5. **Scrubbing.** Moving the timeline while playing seeks and resumes playback at
   the chosen review speed. Moving it while paused remains paused. Rapid seeks must
   not leave playback stopped or resume after an explicit Pause.
6. **Export.** Keep the display awake, show Cancel during video rendering, and play
   one short completion chime plus haptic after success. After completion replace
   Export video with Exported, Share and Save to Photos. Reuse an existing export
   when its edit and referenced sources still match, including after Undo/reopen.
   A new edit enables a new export; previous exports and source files stay intact.
7. **Snapping.** Enabled by default, toggled directly in Tools → Settings. Snap seeks/marks to nearby cuts on release, with tactile feedback. Preserve
   frame stepping. Ripple-trim targets only the stationary playhead, with a bounded
   time tolerance; its own starting edge must not prevent small adjustments. The
   selection bar stays uncluttered; no separate magnet is added in this revision.
8. **Video or photo.** Insert photos and videos together in tap order or use Record
   here at the current playhead, keeping the project's canvas shape. Each photo
   becomes a silent three-second clip. Selected media is stored in the project.
   A Record-here session starts a fresh take; paused capture cannot accidentally
   change from normal continuation into insertion or vice versa. Pause/resume
   segments form one undoable insertion. Leaving insertion ends that take. Normal
   Continue recording still appends. Undo/deletion removes timeline references only;
   unused takes remain available in Video or photo. Incomplete imports are staged away
   from recoverable original recordings.
9. **Image.** Photos picker, transparent PNG support, drag/pinch placement, logarithmic
   size control, opacity, optional position sliders and duration controls. A range
   sets its initial duration; otherwise start at the playhead with a three-second
   default. Reopen/replace/remove through timeline effects or Tools. Preview and
   output use matching alpha compositing. Archives retain image assets across the
   entire undo/redo history. Missing images produce a replace/remove message and
   never prevent backing up existing recordings and editing history.
10. **Color/HDR.** HDR defaults on where the current camera/format supports it, with
    persistent HDR/SDR controls before recording and while paused only (explicitly
    confirmed). Active-take controls are locked. Select compatible formats while
    retaining framing and per-camera zoom. HDR uses 10-bit HEVC with BT.2020/HLG
    tags through capture, compositor and export; SDR uses explicit Rec.709 tags.
    Let supported camera automatic dynamic-range processing operate in SDR too.
    Unsupported combinations clearly report SDR; landscape-selfie compatibility is
    discovered at runtime. Do not apply a compensating contrast filter to all footage.

The previous forced-SDR pipeline is a plausible contributor to the reported flat
appearance. A matched scene recorded by YouRec and Apple's Camera is still needed
to separate HDR display differences from exposure/white-balance/tone-mapping differences.
Apple documents [HDR video settings](https://support.apple.com/en-ie/guide/iphone/iph2cafe2ebc/ios)
and [capture format configuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat).
Correct metadata and encoding are verified; identical Camera-app rendering is not promised.

New edits save schema 2, which older builds reject without rewriting the project.
Schema 1 remains readable. This prevents rollback builds from silently stripping
Mirror/Image edits from current and historical states.


### Settings belong to their workspace (24 October 2026)

The editor's Tools panel ends with a Settings section, after existing project
effects. Each preference is an icon card, not a gateway to a separate Settings
screen. Boolean cards show On/Off, toggle immediately, and keep Tools open;
preferences needing more controls can open their own configuration view.
Current cards are Snap to cuts and Match listening levels. Both keep their saved
values across launches and apply across projects without adding history steps.
The listening-level shortcut in Audio filters uses the same live preference.
The timeline-span menu is for timeline view options; recorder Settings contains
only capture, camera, framing, zoom and microphone preferences and recording info.


### Setting explanations and timeline boundaries (24 October 2026)

Touch and hold an editor setting to read an explanation; opening help must never
change the preference. Ordinary taps still toggle immediately. VoiceOver offers
an Explain setting action. Snap help names clip boundaries and the Pauses-effect
limitation; listening-level help clarifies preview-only compensation and unchanged
export gain.

Timeline clips use rounded outer corners spanning thumbnail and waveform, with a
small gap that waveform strokes and effect underlines cannot paint across. Narrow
clips remain visible without rounding. Clip numbers use larger, padded monospaced
badges; in the compact timeline effect labels begin after the number and give way
when space is insufficient. These changes affect drawing only, preserving timing,
snapping, selection and trim positions.

### Transitions at clip boundaries (24 October 2026)

Transition is available in Tools and at exact timeline joins, including project
start and end. Away from a join, the tool explains where to place the playhead.
Existing transitions have a timeline marker and can be reopened, adjusted or
removed. Apply and Remove each create one persistent undo step; Cancel changes
nothing. The original source clips and trims are never altered by a transition.

The original set is Dissolve, Fade through color (default black), Wipe and Split screen.
Dissolve, wipe and split use real overlap: a two-second overlap makes the project
two seconds shorter. Fade through black keeps length unchanged. Opening and
closing transitions treat the missing neighbor as black and retain project length.
Windows are constrained by the adjacent clips and any other transitions on them;
duration presets are 0.5, 1, 2, 3, 5 and 7 seconds, and the slider extends beyond
10 seconds when the available footage permits it. Unavailable presets are disabled;
there are never three simultaneous videos. The requested duration is retained when
trimming, speed or Pauses temporarily limits the effective duration.

Split screen supports left/right and top/bottom layouts, a movable divider,
independent panning and pinch zoom for each picture, reset, and an audio choice
between crossfade, first clip or second clip. The initial layout is top/bottom for
portrait output, left/right for landscape; explicit layout choices are retained.
Pictures fill their panes
without stretching; existing crop and mirror choices remain respected, and
letterbox bars are excluded from pane framing. Short entry/exit blends surround
the held split. Titles and images remain over the full output frame, with shared
overlay identities drawn once. Framing and playback use the export compositor.

Timeline joins represent overlap midpoints. Snapping, source-time mapping, clip
selection and trim feedback use that layout. Marking within a transition aligns
the mark to its join; splitting inside a transition requires shortening/removing
it first. Moving, deleting or inserting at a join removes its transition when its
exact neighbor identities no longer match; Undo restores the whole prior state.
Non-transition tool workspaces inspect complete clips without transition framing;
the main editor shows the composed joins. Projects using the original transitions use document version 3. The expanded
settings below use version 4 so older builds cannot silently discard them or
change running time.


### Expanded transitions and independent sound timing (25 October 2026)

The style picker separates choosing a transition from adjusting it. The picture
preview remains visible while the controls scroll, in portrait and landscape.
Every effect is editable/removable through its existing timeline marker; Apply
creates one persistent undo step. Cancel leaves the project unchanged.

| Style | Controls and behavior |
| --- | --- |
| Dissolve | Blend the two moving pictures. |
| Fade through color | Any opaque sRGB color, default black; at a project edge the missing neighbor uses that color. |
| Wipe | Soft or hard edge, freely adjustable direction from −180° to +180°. |
| Split screen | Two movable, zoomable pictures and a movable horizontal/vertical divider. |
| Hitchcock | Reveal the incoming scene through the outgoing scene's shadows, or reverse to highlights first. Perceptual luminance masking handles HDR highlights without a last-frame cut. |
| Whip pan | Directional motion blur on one axis, reversible, with no bounce. Starts at eight frames (0.267 s at 30 fps); the user can choose longer durations. |
| Flash Cut | Single-frame glimpses of the incoming scene become more frequent; duration, count and acceleration are adjustable. Extremely short durations limit the number of distinct flashes. |
| still | Hold the actual last visible outgoing frame for a chosen duration, then cut or dissolve. The exit dissolve has its own duration. At project start the held frame is black. |
| Defocus | Optical aperture/bokeh blur with highlight discs, adjustable strength; refocus on the next scene. Broad blur kernels are evaluated at reduced resolution while preserving their output-picture size. |

Applicable moving transitions have an additional midpoint hold, initially zero.
Both pictures keep playing while the effect stays at 50%; the hold adds to the
picture transition duration. Fade-through-color holds the selected solid color.
Flash Cut uses its flash timing instead; still uses its explicit freeze duration.
Default solid-color holds and still freezes add project time; longer moving
holds consume more real overlap. The workspace reports the resulting project
length change. Short neighboring clips proportionally fit the required timing,
with a visible explanation and all requested values preserved.

Every style has an Audio timing section:

- Start offset defaults to zero. Negative values start the sound transition before
  the picture transition (J-cut); positive values start it afterward (L-cut).
- Audio blend controls how long the old sound takes to fade into the new sound.
  Zero is an audio cut with a brief click-prevention ramp.
- Fine ±0.1 s controls and a 0 s button complement the offset slider. A two-row diagram
  shows the actual picture and sound intervals after fitting.
- Adjusting either control selects an independent continuous crossfade for every
  style. Reset restores its automatic sound behavior. Unmodified color fades
  retain their fade-out/fade-in sound; unmodified still freezes have no artificial
  stretched audio. Split's historical First/Second choices remain selectable.
- The union of picture and audio intervals determines the logical transition
  footprint and project running time. Both tracks of each source share one clock:
  offset sound changes when it becomes audible, never lip sync. A long audio lead
  can make incoming footage play underneath the outgoing picture or freeze.
- At the project edges the absent scene is silent. No transition can require a
  third simultaneous source or overrun available neighboring footage.

Optional fields preserve existing project behavior when absent. New settings,
source trims and persistent Undo/Redo are covered by save/reopen checks.


### Direct volume control, clipping feedback and waveform detail (27 October 2026)

The existing Volume control also supports holding and sliding vertically. Up
raises gain and down lowers it in 0.5 dB steps, from −40 to +12 dB. A floating
readout gives absolute gain and the change. Step hysteresis, a stronger haptic
and detent at 0 dB help precise selection. Holding near a screen edge continues
stepping, so the bottom toolbar does not limit downward adjustment. Sliding
sideways cancels. A tap opens the detailed volume/mute/reset controls.

Only selected audio parts or the marked range change, including the audio of
linked video/audio selections. One release creates one persistent undo step.
Mixed levels remain Mixed until a common absolute level is chosen: the first
upward step starts at the loudest selected level, the first downward step at the
quietest. Opening and applying the detailed editor without changing a control
preserves the individual gains and mute states. Gain-only boundaries use a
10 ms ramp without fading through silence. Playback auditions the chosen level;
if it was playing at release, it resumes after the committed preview reloads.

The handle and readout turn red when the selected gain would make the mixed
post-effects audio exceed full scale. The detailed slider's actual thumb turns
red too. Analysis uses decoded floating-point samples after enhancement, speed
and envelopes, and includes unselected overlapping audio and cancellation. It
solves a safe gain interval, rather than treating all positive dB as clipping.
While analysis is pending or unavailable, the UI states that explicitly. This is
sample-peak detection, not intersample true-peak or AAC reconstruction prediction;
it cannot determine whether source audio was already distorted before import.

Waveforms retain a lightweight 10 ms overview and decode signed 1 ms min/max
envelopes only for visible regions at high zoom. Four-second tiles are cached
in memory, capped at 64 tiles (about 2 MB); no scratch PCM files are created.
Columns are one point wide and aligned to timeline content. Exact peak queries
preserve transient location; square-root amplitude makes quiet speech readable.
Processed audio regions use their processed waveform. Trims, speed, moves and
silent holds preserve source-time alignment. A single selected audio row grows
only within the space left by other rows. Linked cuts still use video-frame
boundaries; a detailed waveform does not promise sample-accurate editing.

The project browser's Edit action has a blue/cyan treatment, a visible text label
and the existing generous tap area. Recorder presentation defaults to the full
recorded frame, using delivered buffer dimensions even before recording starts.
An explicit Fill screen preference remains consistent across idle, Record,
Pause, Resume and Stop; the fixed take canvas is retained through camera changes.


### Volume playback follow-up (28 October 2026)

Live volume changes now update a persistent audio tap instead of replacing the
player's mix at every drag step, which could stall playback on the iPhone 14.
A 10 ms ramp changes only the selected gain; original fades, range boundaries
and other tracks keep their envelopes. Cancellation restores the original level.


## Subtitles (implemented, November 2026)

Qwen3-ASR-0.6B runs offline after an optional model download. Transcribe the
selected range or the whole project. Pause-based approximate word timing supports
adjustable phrase length, playback-following sentence editing, four visual
styles and consistent preview/export. Timing follows source audio through
edits; structural changes disable regrouping until re-transcription. Removing
subtitles removes the complete transcript, with Undo. See
[the implemented specification](docs/SUBTITLES.md) for UI, persistence, download
hosting, dependencies, tests and limitations.
