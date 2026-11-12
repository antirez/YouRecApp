# Recording and project recovery

## The promise to the person filming

If YouRec crashes 19 minutes into an interview, reopening it should bring back the playable interview in the right project. If the timeline itself is damaged, the person should still be able to watch and save the original. They should be told about any known missing footage before relying on the recording.

For an **app crash**, the release targets are zero loss of previously saved takes and acknowledged edits, and at most two seconds lost from an active take once its first fragment has been written. Aim for the first recoverable picture and sound within one second of the first captured samples. Measure from actual capture timestamps. Track sudden device restart separately. Losing the phone or erasing the app requires a copy outside the app.

## What build 185 already does

- The recorder writes a QuickTime movie directly into its project, with a two-second fragment interval. Apple provides this facility so interrupted movies can be playable. Actual recoverable duration depends on the media the encoder and filesystem have written. [Recorder implementation](../YouRec/CaptureSegmentWriter.swift) · [Apple on movie fragments](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval) · [Apple on the first fragment](https://developer.apple.com/documentation/avfoundation/avassetwriter/initialmoviefragmentinterval)
- On launch, YouRec scans **projects whose manifest it could open** for unindexed recordings. It can attach a readable movie or preserve an unreadable one under **Unfinished recordings**. An invalid effects file can currently send a playable movie there too. The importer hashes the movie before attaching it. [Project loading and recording recovery](../YouRec/ProjectStore.swift)
- Edit snapshots have content hashes. The app writes them before atomically replacing `project.json`. That file contains the source list, recording ledger, ordered history and current revision. Losing it can hide the whole project. Losing an older history file can prevent opening the full editor even when the current edit is healthy. A failed edit save retains the draft in memory and offers Retry. [Project persistence](../YouRec/Project.swift) · [Save and retry](../YouRec/ProjectStore.swift)
- Export can resume from checkpoints. Starting a replacement export currently removes prior completed exports before rendering the new file. A crash or full disk at that point costs the previous export. [Export lifecycle](../YouRec/EditorController.swift) · [Export checkpoints](../YouRec/ExportCheckpoint.swift)

## Implementation order

Start the hard-kill tests while making three smaller fixes. Retain the last successful export until replacement succeeds, return an explicit unsaved result from a failed project write, and open playable footage even when its effects recipe is damaged.

### 1. Establish how much of a take really survives

Build a repeatable hard-kill test first. An independent controller terminates the app without running Stop or cleanup. Use a numbered picture and synchronized audio pulses to identify the last **decodable** picture and sound. Save the interrupted file before recovery, reopen using the ordinary app, and export the recovered take. Compare the source, editor and export. File size and container duration alone cannot establish success.

Test the existing writer first, then try a one-second initial fragment with the current two-second cadence. Keep the simpler single-file writer if it passes. If the tail loss exceeds the target or one bad tail repeatedly costs an entire take, prototype separately committed fragments with one continuous encoder and capture clock. Preserve initialization data, ordering, color metadata and audio continuity. The editor must still see one take. Reject any implementation that introduces dropped frames, audio seams or a second encode on normal Stop.

### 2. Record which take belongs where before capture starts

Write a small durable receipt before accepting the first sample. Include a stable take and segment ID, project ID, media path, order and the intended append or **Record here** location. Refuse to show Recording if the receipt cannot be written. Keep movies, receipts and sidecars outside disposable work directories.

After Stop, finalize the media, validate the usable tracks and commit its source entry and placement to the project. Mark the receipt complete only after the project save succeeds. A retry after a crash must attach the take exactly once, including if the crash occurred after the save but before marking completion. Keep the current hash and archive integrity checks, but allow a long integrity check to resume without blocking access to other projects. If a later edit removed the intended insertion point, present the take in **Original recordings** and let the user place it. Preserve intentional cuts, deletions, Undo and Redo.

Recover the movie independently of bookmarks and effects. If an effects file is damaged, offer the playable original and retain the file for repair. If only part of a movie decodes, extract that part to a new file, preserve the interrupted file, and identify which tracks and time span were recovered. Locked or temporarily inaccessible files wait for an unlock and retry.

### 3. Make the timeline recoverable independently of the movies

Keep a small rolling set of validated project manifests alongside the existing immutable history. Retain a known-good pre-migration version. Publish a generation only after its new dependencies are written and checked. Keep history files needed by retained generations, including Redo. Distinguish a durable save from a draft in memory at the store API and in the editor. If storage prevents either the normal save or a small recovery journal from persisting, show **Changes not saved** with Retry and keep the last saved revision available.

Persist data during normal operation. On sudden termination, the final save callback may never execute. For restart resilience, flush new dependencies at commit boundaries before publishing the manifest, then verify the filesystem behavior on device. A generation is eligible for restoration only if its required metadata is intact. Use a small transaction log for pending changes if needed. Keep full movie copies and per-frame synchronous disk writes off the recording path.

On open, try the latest complete generation. If only old Undo data is damaged, offer the newest valid current timeline with the available history. If an earlier generation must be used, tell the user its time and keep the damaged generation. If every generation fails, still list the project and offer **Open original recordings**, **Save originals to Files**, and **Create recovered project**. Rebuild into a separate project. Existing installations should acquire this protection on their next successful save. Keep the current conservative orphan scan for older takes without receipts.

### 4. Make exports and low-storage behavior safe

Keep the last successful export while rendering its replacement. Write the new file under a unique name, verify playback and expected duration, then publish its receipt. Only then make the old export eligible for cleanup. On cancellation, lock, failure or restart, the prior movie stays available to save to Photos. If both files cannot fit, show the space required and let the user decide whether to free space.

Build on the recorder's existing free-space checks. Use the measured write rate and time needed to close a take to size the safety margin. Test disk-full errors on the media, receipt, manifest and export writes separately. Pause early enough to finalize the take. Automatic cleanup may reclaim reproducible caches, while originals, unfinished takes, retained edits and the last good export remain protected.

### 5. Give recovery a normal place in Projects

Recover unambiguous takes automatically. Show one dismissible result, for example **Recovered 18 min 42 sec of your recording · Review**. Report any known gap. When the loss is unknown, say so. Offer **Review**, **Save original** and **Later**. A failed recovery of one take should leave the camera and other projects usable. If repair itself repeatedly crashes, offer a way to open originals without starting that repair again.

In **Original recordings**, show each take's recorded duration independently of the edited timeline. A filmmaker who sees a 12-minute edit can open the original 16-minute take, compare them, and choose whether to reinsert a missing section while keeping their other edits.

Make the existing project archive easier to find as **Back up project**. Verify that a copy saved outside the app restores on a clean installation with its originals, timeline and history. A Photos copy is useful for watching the finished movie. The project archive is what lets the filmmaker continue editing on another device.

## Release gates

| Failure we inject | Evidence required |
| --- | --- |
| Kill before the first fragment, during a 20–30 minute take, at a fragment boundary, on Pause, and immediately after Stop | Measure tail loss from both tracks. For a source with synchronized picture and sound, require recovered sync within one video frame at the beginning and end. Test single and dual camera, the principal SDR/HDR/Log formats on supported hardware, and camera or microphone switches. Report the worst observed loss and any audio-only or video-only tail. |
| Kill between each recording, import, save and recovery commit, including a second kill during repair | Relaunch twice. Each completed take appears exactly once in the intended project and position. Earlier source hashes, deliberate cuts and valid edits match the baseline. |
| Truncate a movie tail, damage an effects sidecar, corrupt the latest manifest, remove an older Undo snapshot, or supply a newer unsupported schema | The app preserves the bytes, exposes healthy media and reports what it restored. An older app never overwrites a newer project it cannot interpret. |
| Exhaust storage, lock or restart the device, interrupt replacement export or archive, and restore the archive to a clean installation | The preceding good movie or project remains accessible. The new file is offered as complete only after it passes validation. Recovery survives another interruption. |

Run filesystem fault injection on every change to persistence. Run physical camera kills on the iPhone 14 using isolated projects, plus the 17 Pro for its camera formats. Use disposable storage or injected write failures for exhaustion tests. Keep source hashes, recovered durations, sample counts and A/V sync measurements. Check uninterrupted recording too. Gate the public release on those results.
