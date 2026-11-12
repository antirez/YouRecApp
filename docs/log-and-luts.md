# Log recording and color grades

## Product behavior

- Choose SDR, HDR or Log under **Camera settings → Recording color**.
- Log means genuine camera Apple Log / Apple Log 2, encoded as 10-bit HEVC.
  Capability is negotiated per physical camera, format and framing. Two-camera
  composition remains SDR. The recording format can change before a take or
  while paused, never halfway through an active segment.
- Monitoring converts Log to a normal-looking image. Source recordings retain
  the camera signal for subsequent grading; normal editor export is graded video.
- Color LUTs acts on the selected video range/items, or the complete video when
  nothing is selected. Before/After and preview inspection remain available.
- Built-in, Imported, Favorites and Grades share one compact thumbnail library.
  Imports come from Files. Each imported LUT declares whether it expects Rec.709,
  Apple Log, or Apple Log 2; its output must be Rec.709.
- Strength controls the creative look. At zero, camera interpretation and
  exposure/highlights/white-balance correction remain in place.
- Highlights is visible beside the main look controls. Its −100…+100 slider
  defaults to zero. Move left to recover bright detail without lowering shadows
  or most midtones; move right to brighten highlights. Tap the value to reset.
  It operates on the source before display conversion and the LUT. It cannot
  reconstruct details clipped by the sensor. A highlights-only grade is retained
  and can be reopened, scoped, undone and saved like other color adjustments.
- A named grade saves the look, input interpretation, strength, exposure, highlights, warmth
  and tint. Projects own immutable copies of LUT payloads, including references
  retained by Undo/Redo and project archives.

## Color implementation

The two Apple profiles share a transfer curve but have different primaries:
Apple Log uses BT.2020; Apple Log 2 uses Apple Wide Gamut. We explicitly decode
unmanaged camera code values into linear Rec.709 working RGB. The Log metadata,
not the presence of 10-bit buffers, identifies the source interpretation.

The viewing shoulder is original code: luma is unchanged through 0.6; above
that, with `d = Y − 0.6`, it tends toward 1 using `0.6 + 0.4*d/(d + 0.4)`.
This rational shoulder replaces build 150's exponential shoulder, which made
recoverable highlights several stops above reference white effectively identical.
Middle gray and shadows are unchanged. RGB is scaled by the luma ratio; colors
outside display gamut move toward neutral at the same luma instead of clipping
individual channels. This conversion
does not run on the original recording. A custom Log-to-709 LUT receives Log
code values before this viewing shoulder, so technical conversion is not doubled.

Selective Highlights runs after exposure/white balance, before either LUT path.
At zero it bypasses exactly. Luma through 0.35 stays unchanged. For negative
amount `h`, let `d = max(Y − 0.35, 0)` and `a = −6*h`; the new upper luma is
`0.35 + log(1 + a*d)/a`. Positive amounts use
`0.35 + d*(1 + 2*h*d/(d + 0.35))`. Both have unit slope at the knee and remain
monotonic. RGB scales by the luma ratio. There is no spatial mask or automatic
per-frame adaptation, avoiding halos and pumping. This is an original global
curve, not reconstruction of sensor-clipped highlights.

CUBE files use red-fastest sample ordering, explicit input domains, and bounded
finite values. Standalone 3D cubes (2–65 samples per dimension) and standalone
1D curves (2–16,384 samples, retaining every sample) are supported.
Combined shaper+cube files and unknown directives produce an explicit error.
Maximum input size is 32 MB. Imported assets use SHA-256 names under the project.

## Local highlight recovery — build 153

An optional 0–100% adjustment in Color LUTs, visible when the selected scope
contains native Log footage. Zero is an exact bypass; Natural chooses 100%.
Exposure, the existing global Highlights control, recovery and creative look
strength remain independent. Settings persist in named grades, project history,
archives and Undo/Redo. A grade reused on non-Log clips retains the setting but
does not apply it there; a mixed scope processes only its Log clips.

The original GPU implementation separates scene log-luminance into a guided
base and residual detail. Radius is 60 pixels at a 1080-pixel short edge, scaled
with source resolution; epsilon is 0.12. The bright base receives the study's
highlight compression (strength 12, knee 0.35) and viewing shoulder. Detail is
reattached at unity, with a soft upper shoulder to contain spikes. No sharpening,
face mask or temporal exposure adaptation is introduced. Image edges use clamped
extension rather than the experiment's reflected padding, so their exact pixels
differ slightly. Strength blends the original and recovered luminance targets.

The scalar viewing curve is inverted to express the result back in scene-linear
RGB, preserving source chroma for the actual output transform. Thus built-in and
Rec.709-input LUTs receive the usual display conversion once; Log-input LUTs
receive the adjusted scene encoded in their declared Log profile. They are never
fed an already converted SDR image. A custom LUT can still flatten or clip detail
through its own mapping. Original recordings are untouched.

Strong recovery can expose noise or spatial halos. It is a shot adjustment,
not sensor-clipping reconstruction, a mandatory Log interpretation, or an HDR
output transform. Matching consecutive shots and preserving intended lighting
remain the user's decisions.

## Reference material

- [Apple Log capture color space](https://developer.apple.com/documentation/avfoundation/avcapturecolorspace/applelog)
- [Apple Log 2 capture color space](https://developer.apple.com/documentation/avfoundation/avcapturecolorspace/applelog2)
- [Apple profile white papers](https://developer.apple.com/download/all/?q=Apple%20log%20profile)
- [ASWF camera transform reference](https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/main/src/OpenColorIO/transforms/builtins/AppleCameras.cpp)

Profile constants were cross-checked against the ASWF reference. The Swift,
Core Image kernels and built-in looks are original implementation code; no
third-party creative LUTs are bundled.
