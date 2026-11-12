#!/bin/bash
set -euo pipefail
mkdir -p "$1"
ffmpeg -v error -y -f lavfi -i 'testsrc2=size=384x256:rate=30:duration=0.067' -vf "pad=392:260:8:4,crop=384:256:x='8*(1-n)':y='4*(1-n)'" -frames:v 2 -c:v libx264 -crf 10 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 "$1/night-flow.mov"
ffmpeg -v error -y -f lavfi -i 'color=c=0x141B21:size=384x256:rate=30:duration=2,drawbox=x=90:y=50:w=185:h=140:color=0x2D221C:t=fill,drawbox=x=130:y=85:w=20:h=25:color=0x080808:t=fill,drawbox=x=210:y=85:w=20:h=25:color=0x080808:t=fill,drawbox=x=145:y=145:w=75:h=8:color=0x090909:t=fill,noise=alls=12:allf=t+u:all_seed=731' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' -c:v libx264 -crf 10 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac -shortest "$1/night-source.mov"
