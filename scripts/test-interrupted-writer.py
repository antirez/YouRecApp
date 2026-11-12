#!/usr/bin/env python3
"""Kill the production segment writer at numbered camera frames. Run scripts/test-core.sh
--project-recovery with YOUREC_TEST_DIRECTORY set first; pass that directory here."""
import argparse
import concurrent.futures
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("build", type=Path)
args = parser.parse_args()
binary = (args.build / "core-tests").resolve()
root = Path(tempfile.mkdtemp(prefix="killed-writer-", dir=args.build)).resolve()
ffmpeg = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error"]
clock = "nullsrc=s=320x180:r=30:d=10,geq=lum='if(lt(Y,90),if(bitand(N,pow(2,floor(X/32))),215,30),if(eq(mod(N,30),0),215,30))':cb=128:cr=128"
tone = "aevalsrc='if(lt(mod(t,1),1/30),0.7*sin(2*PI*1000*t),0)':s=48000:d=10"
subprocess.run(ffmpeg + ["-f", "lavfi", "-i", clock, "-f", "lavfi", "-i", tone, "-c:v", "libx264",
                         "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", str(root / "clock.mov")], check=True)

def check(frame):
    output = root / f"frame-{frame}.mov"
    env = dict(os.environ, YOUREC_KILL_FRAME=str(frame), YOUREC_KILL_OUTPUT=str(output))
    with (root / f"child-{frame}.log").open("w") as log:
        proc = subprocess.Popen([str(binary), str(root), "--abrupt-writer-child"], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 35
            while not Path(str(output) + ".armed").exists():
                if proc.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f"Writer did not reach frame {frame}; see {log.name}")
                time.sleep(0.02)
        finally:
            if proc.poll() is None:
                os.kill(proc.pid, signal.SIGKILL)
            proc.wait()
    # Decode actual picture and sound. Container duration can include an incomplete tail.
    video = subprocess.run(ffmpeg + ["-i", str(output), "-map", "0:v:0", "-fps_mode", "passthrough", "-pix_fmt", "gray", "-f", "rawvideo", "-"], capture_output=True)
    pixels = video.stdout
    count = len(pixels) // (320 * 180)
    if count == 0:
        return {"kill_frame": frame, "readable": False, "pass": frame < 30}
    def number(i):
        start = i * 320 * 180 + 40 * 320
        return sum((pixels[start + 16 + 32*b] > 128) << b for b in range(10))
    ids = [number(i) for i in range(count)]
    audio = subprocess.run(ffmpeg + ["-i", str(output), "-map", "0:a:0", "-f", "f32le", "-ac", "1", "-ar", "48000", "-"], capture_output=True)
    samples = [v[0] for v in struct.iter_unpack("<f", audio.stdout)]
    loss = max((frame - ids[-1]) / 30, (frame + 1) / 30 - len(samples)/48000)
    details = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries",
        "frame=media_type,best_effort_timestamp_time", "-of", "json", str(output)]))["frames"]
    video_times = [float(x["best_effort_timestamp_time"]) for x in details if x["media_type"] == "video"]
    audio_start = next((float(x["best_effort_timestamp_time"]) for x in details if x["media_type"] == "audio"), 0)
    onsets = []
    last = -10000
    for i, value in enumerate(samples):
        if abs(value) > 0.18:
            if i - last > 6000:
                onsets.append(audio_start + i / 48000)
            last = i
    offsets = []
    for i, ordinal in enumerate(ids):
        if ordinal % 30 or i + 2 >= count: continue
        event = ordinal // 30
        offsets.append(abs(onsets[event] - video_times[i]) if event < len(onsets) else math.inf)
    ok = bool(samples) and ids == list(range(ids[0], ids[-1]+1)) and ids[0] == 0 and loss <= 2 and max(offsets, default=0) <= 1/30
    return dict(kill_frame=frame, readable=True, last_frame=ids[-1], audio_seconds=len(samples)/48000,
                loss_seconds=loss, sync_seconds=offsets, **{"pass": ok})
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    records = list(pool.map(check, [12, 32, 47, 69, 99, 155, 209]))
print(root)
print(json.dumps(records, indent=2))
(root / "result.json").write_text(json.dumps(records, indent=2))
raise SystemExit(0 if all(row["pass"] for row in records) else 1)
