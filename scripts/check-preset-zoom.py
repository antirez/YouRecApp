#!/usr/bin/env python3
"""Check an isolated 30 fps take from testSixToOneZoomPresets.

Point the stationary phone at a textured, stationary scene. Run this on the
saved movie with Python, OpenCV and NumPy. Camera zoom readbacks alone miss
the repeated frames and skipped magnifications at a sensor sampling switch.
"""
import argparse
import math

import cv2
import numpy as np


def measure(previous, current):
    points = cv2.goodFeaturesToTrack(previous, 450, 0.006, 5)
    if points is None or len(points) < 6:
        return None
    tracked, valid, _ = cv2.calcOpticalFlowPyrLK(
        previous, current, points, None, winSize=(25, 25), maxLevel=4
    )
    good = valid[:, 0] != 0
    if np.count_nonzero(good) < 6:
        return None
    matrix, inliers = cv2.estimateAffinePartial2D(
        points[good], tracked[good], method=cv2.RANSAC, ransacReprojThreshold=0.85
    )
    if matrix is None or np.count_nonzero(inliers) < 6:
        return None
    return math.log(math.hypot(*matrix[0, :2]))


def check(path):
    video = cv2.VideoCapture(path)
    previous = None
    previous_time = None
    moves = []
    while True:
        ok, image = video.read()
        if not ok:
            break
        time = video.get(cv2.CAP_PROP_POS_MSEC) / 1000
        height, width = image.shape[:2]
        small = cv2.resize(image, (424, round(424 * height / width)), interpolation=cv2.INTER_AREA)
        current = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
        if previous is not None:
            change = measure(previous, current)
            # Collect consecutive widening frames, allowing a brief ISP stall.
            if change is not None and change < -0.003:
                if not moves or time - moves[-1][-1][0] > 0.25:
                    moves.append([])
                moves[-1].append((time, time - previous_time, -change))
        previous, previous_time = current, time
    video.release()
    full_moves = [move for move in moves if 5.5 <= math.exp(sum(step for _, _, step in move)) <= 6.5]
    if len(full_moves) < 2:
        raise SystemExit("Could not measure two complete 6× → 1× moves. Check the framing and take.")
    # At the steepest point a one-second quintic ramp travels 1.875 times
    # the mean speed in log magnification. Allow 3% for optics and registration.
    for move in full_moves:
        elapsed = move[-1][0] - move[0][0]
        if not 0.7 <= elapsed <= 1.1:
            raise SystemExit(f"Expected a one-second double-tap override, measured {elapsed:.2f}s of motion.")
        worst = max(move, key=lambda row: row[2])
        print(f"{move[0][0]:.2f}s: largest single-frame widening {math.expm1(worst[2]):.1%}")
        for time, dt, step in move:
            if not 0 < dt < 0.055 or step > math.log(6) * 1.875 * dt + math.log(1.03):
                raise SystemExit(f"Discontinuous zoom at {time:.3f}s ({dt * 1000:.1f} ms, {math.expm1(step):.1%}).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("movie")
    check(parser.parse_args().movie)
