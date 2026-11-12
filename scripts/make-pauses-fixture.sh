#!/bin/bash
set -euo pipefail
# Deterministic public UI fixture: 18 seconds, nine 0.8-second quiet windows.
# Usage: scripts/make-pauses-fixture.sh /path/to/editor-fixture.mp4
# Refuses to overwrite an existing file. Requires ffmpeg.
if [[ $# != 1 ]]; then
    echo 'Usage: scripts/make-pauses-fixture.sh <output.mp4>' >&2
    exit 1
fi
ffmpeg -hide_banner -loglevel error -n \
    -f lavfi -i 'testsrc2=size=540x960:rate=30:duration=18' \
    -f lavfi -i 'aevalsrc=if(lt(mod(t\,2)\,0.8)\,0.0001\,0.2)*sin(2*PI*440*t):s=48000:d=18' \
    -c:v libx264 -preset ultrafast -crf 26 -pix_fmt yuv420p -c:a aac -shortest "$1"
