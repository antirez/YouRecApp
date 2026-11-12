# Subtitles — first implementation

Implemented 1 November 2026. Phrase captions with approximate word times, using
Qwen3-ASR-0.6B and pause detection; no forced alignment model or word karaoke.

## User workflow

- Editor → Tools → Subtitles. The marked/selected range is transcribed; without
  a selection the scope is the whole project. The preview plays only this scope;
  its seek slider stops on the last included frame, never on the next clip.
- Download the speech model once (712,705,305 bytes, shown as 713 MB). Subsequent
  transcription is entirely offline. Language can be automatic or specified.
- Transcribe reads the edited audio mix, including gaps, speed and enhancement.
  It never sends recordings or text to a server. Progress and cancellation are
  available; cancellation or a failed job leaves the existing captions intact.
- Max words per subtitle (1–16, default 6) regroups the stored words immediately.
  Punctuation and pauses can end a caption earlier than the limit.
- Appearance offers Plain, Bold, Box and Highlight styles, five colors, size
  and vertical position. Highlight means a colored phrase background, not
  word-by-word highlighting. Preview and export use the same rasterizer.
- The playback section shows two preceding and two following captions around
  the highlighted current caption. A complete, collapsible transcript follows.
  Tap a sentence to pause, seek to it and edit it. Save text stays in the top
  bar above the keyboard. Unchanged words keep their timing; replacement words
  share the available phrase interval, and inserted words borrow neighboring
  time. This is a heuristic, not acoustic alignment.
- **Copy full transcript** copies plain text for the entire edited timeline in playback
  order, including corrections saved in the sheet, even when a clip or range is selected.
- Apply commits the draft as one Undo step; Cancel discards the draft. Text,
  grouping, style, removal and Undo/Redo survive project reopening. Removing
  subtitles removes the entire project's transcript and word timing, with a
  confirmation. Removing the downloaded model does not delete captions.

## Timing, edits and persistence

Each audio timeline item owns its words by value, in original source time.
Resolved captions use the item's playback mapping. Splits, moves, trims,
reordering, cuts and speed changes therefore carry text with speech. Copied
items receive new word/phrase IDs; correcting one copy cannot edit another.
Linked horizontal joins retain their constituent items and captions.

A fingerprint records the audio/video structure at transcription: source IDs,
item IDs, positions, mappings and mute state. Structural changes disable the
word-limit control and show “Footage changed. Re-transcribe to change subtitle
grouping.” Existing captions remain editable and usable. Undo to the original
structure re-enables grouping. Styling and gain changes do not invalidate it.
Full re-transcription refreshes the fingerprint. A partial re-transcription
preserves other captions and cannot make an otherwise stale transcript fresh.

Caption boundaries participate in previous/next effect navigation. A Subtitles
chip reopens the project transcript; its removal removes all subtitles. New
projects containing subtitles use schema 8; earlier schemas remain readable.
Unknown future project schemas are rejected rather than silently losing edits.

Overlapping speakers are not diarized. Recognized words are attached to the
strongest eligible audio item at that time, with deterministic tie-breaking.
Complex overlaps and transition mixes remain best effort. Re-transcribe after
major edits. Long continuous speech, noise and very fast speech can produce
noticeable timing drift; the UI deliberately describes timing as estimated.

## Recognition and resource use

The edited mix is streamed as 16 kHz mono PCM into temporary disk storage, with
20 ms RMS windows. An adaptive noise gate finds speech islands; short pauses
are grouped for language context. Continuous speech is split near a low-energy
window, with a hard 12-second inference limit. Estimated word durations are
weighted by word length and allocated inside speech islands, not across silence.
The whole recording is never held in an ML tensor. GPU cache is capped at 64 MB
in addition to live model/tensor memory. Model resources are released when the
job completes or is cancelled. Temporary PCM is removed on every normal exit.

The runtime is an Apache-2.0 Qwen-only subset of `soniqo/speech-swift`, pinned at
`a57702e6f523fa36ac5532d2bdc5f35f701a052c`, with MLX Swift 0.31.4. YouRec adds a
local loader and cancellation. The model runs on Apple Silicon; simulator
builds exclude Intel x86_64. The optional pack contains weights and tokenizer
data only, never executable code. Dependency licenses ship in the app.

## Download hosting and integrity

For this prototype the pack comes directly from Hugging Face:
`aufklarer/Qwen3-ASR-0.6B-MLX-4bit`, immutable revision
`bc441bd1e4295c1f42d9879f056049a925b6e013`. Qwen and this conversion are
Apache-2.0. The app verifies every file's SHA-256 before publishing the complete
pack atomically. Exact sizes and hashes are in `SubtitleModelPack.swift`.
Downloads retain completed files and URLSession resume data where available.
The model lives in Application Support, excluded from device backups. It can
be removed from the subtitle view to reclaim storage.

No account, token, GitHub release or new hosting repository is required. Before
public distribution, mirroring this exact verified pack under a YouRec-controlled
Hugging Face repository would remove reliance on the converter's availability;
that is an operational follow-up, not a dependency of offline transcription.

## Direct placement and preview inspection — 1 November 2026, build 143

- Drag a caption to move the whole subtitle series; pinch it to resize the
  series. The cyan outline during manipulation is the largest caption envelope
  across the **whole project**, including captions outside the tool's selection.
- Every caption uses the same position, font and size. The maximum width and
  height are measured separately; simultaneous speakers include their combined
  stack height. Movement and resizing keep that envelope inside the video with
  a small safe margin. Changing text, grouping, font, style or canvas revalidates
  the placement. An unusually long corrected caption can limit the whole
  series' size; it is never silently clipped to a fixed number of lines.
- Appearance offers System, Modern (Avenir Next), Classic (Georgia), Mono
  (Menlo), and Narrow (DIN Condensed), using system fonts without a download.
  Plain uses regular weight; other styles use the matching bold weight where
  available. Size and horizontal/vertical sliders remain accessible alternatives
  to gestures, with a Reset position and size action.
- Pinch outside the caption to inspect the preview; drag the enlarged view to
  pan. The magnifier in the preview makes all gestures inspect the video, including
  gestures over a large caption. Its hand icon restores caption manipulation.
  Reset preview zoom returns to 1×; inspection can never zoom below 1× and is
  never saved in the project or exported.
- Other editor tool previews now support inspection too. Tools whose canvas
  already edits text, images, crop handles, overlapping video placement or split
  transitions have Inspect/Edit controls to keep the two operations separate.
  Video effects already had inspection; parameter rebuilds retain its zoom.
- Caption typography is laid out once in a canonical canvas with a 1080-pixel
  short edge. Resizing scales that layout rather than changing line breaks.
  The editor and compositor share the same layout, constraints and rasterizer;
  only visible captions are rasterized and cached. The editor draws its captions
  over the uncaptioned player directly, so a drag does not rebuild AVComposition.
- Initial preview seeking now precedes asynchronous thumbnail preparation.
  Completing thumbnail work must never reset a seek the user already made.
- Optional JSON font/x fields let build-142 projects load centered in the system
  font. All edits retain existing Apply/Cancel and persistent Undo/Redo behavior.
