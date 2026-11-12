#!/usr/bin/env python3
"""Run one short, isolated iPhone camera interruption on a developer device.
Snapshot projects and preferences first (docs/CAMERA-QA.md). The output directory
must be new. This command never deletes media from the device. A debug-only,
20-second on-phone watchdog stops the take if the host disconnects.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--device", required=True, help="CoreDevice ID")
p.add_argument("--destination", required=True, help="Xcode UDID")
p.add_argument("--xctestrun", required=True, type=Path)
p.add_argument("--seconds", type=float, default=9.4)
p.add_argument("--color", choices=["sdr","hdr","log"], default="sdr")
p.add_argument("--dual", action="store_true")
p.add_argument("--four-k", action="store_true")
p.add_argument("--output", required=True, type=Path)
args = p.parse_args()
if not 5 <= args.seconds <= 15: p.error("Physical checks are limited to 5–15 seconds")
if args.dual and args.color == "log": p.error("Use Log with one camera")
root=args.output.resolve()
root.mkdir(parents=True, exist_ok=False)
spec=plistlib.loads(args.xctestrun.read_bytes())
target=spec["YouRecUITests"]
target["EnvironmentVariables"].update(YOUREC_EXTERNAL_KILL_SECONDS=str(args.seconds), YOUREC_KILL_COLOR=args.color,
                                    YOUREC_KILL_DUAL="1" if args.dual else "0",
                                    YOUREC_KILL_QUALITY="ultraHD4K" if args.four_k else "hd1080")
recipe=args.xctestrun.resolve().with_name("CrashTest-"+str(uuid.uuid4())+".xctestrun")
recipe.write_bytes(plistlib.dumps(spec))

def device(command, name):
    result=root/(name+".json")
    subprocess.run(["xcrun","devicectl","device",*command,"--device",args.device,"--timeout","20",
                    "--quiet","--json-output",str(result)], check=True)
    return json.loads(result.read_text())["result"]

def processes():
    rows=device(["info","processes"],"processes")["runningProcesses"]
    return [x["processIdentifier"] for x in rows if x["executable"].endswith("/YouRec.app/YouRec")]

def movies(name):
    rows=device(["info","files","--domain-type","appDataContainer","--domain-identifier","com.antirez.yourec",
                 "--subdirectory","Documents/RecorderUITestProjects"],name)["files"]
    return {x["relativePath"] for x in rows if len(Path(x["relativePath"]).parts)==2 and x["relativePath"].endswith(".mov")}

log=root/"test.log"
base=movies("before")
cmd=["xcodebuild","-xctestrun",str(recipe),"-destination","platform=iOS,id="+args.destination,
     "-parallel-testing-enabled","NO","-only-testing:YouRecUITests/EditorUITests/testRecoverExternallyInterruptedCameraTake",
     "-resultBundlePath",str(root/"test.xcresult"),"test-without-building"]
try:
    with log.open("w") as stream:
        proc=subprocess.Popen(cmd, stdout=stream, stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+160
            while "YOUREC_KILL_TEST_ARMED" not in log.read_text(errors="replace"):
                if proc.poll() is not None or time.monotonic()>deadline: raise RuntimeError("Recording did not arm; see "+str(log))
                time.sleep(.15)
            ids=processes(); new=movies("started")-base
            if len(ids)!=1 or len(new)!=1: raise RuntimeError("Expected one new isolated movie and one YouRec process")
            film=new.pop()
            start=int(Path(film).name.split("-")[0])/1000
            time.sleep(max(0,start+args.seconds-time.time()-.35))
            if processes()!=ids or abs(time.time()-start-args.seconds)>3: raise RuntimeError("Process or capture timing changed; refusing to signal")
            sent=time.time()
            device(["process","signal","--signal","9","--pid",str(ids[0])],"signal")
            (root/"kill-timing.json").write_text(json.dumps(dict(film=film,start=start,sent=sent,returned=time.time(),requested=args.seconds)))
            (root/"clock-enabled").touch()
            if proc.wait(timeout=160)!=0: raise RuntimeError("See result bundle for relaunch outcome")
        finally:
            if proc.poll() is None: proc.terminate()
finally:
    recipe.unlink(missing_ok=True)
