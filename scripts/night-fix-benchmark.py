#!/usr/bin/env python3
"""Offline research harness. Does not modify YouRec projects or source media.

Dependencies: numpy, OpenCV, PyAV, torch, Pillow. Neural mode loads an
explicitly supplied, separately licensed FastDVDnet checkout and checkpoint.
Original classical pipeline: DIS flow, bidirectional confidence, robust temporal
fusion, restrained spatial chroma cleanup. Both engines share a BT.709 exposure
curve. This is a desktop experiment, not the shipping iPhone effect.
"""
import argparse
from collections import deque
from fractions import Fraction
import hashlib
import importlib.util
import json
from pathlib import Path
import time

import av
import cv2
import numpy as np

LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def linear709(x):
    return np.where(x < 0.081, x / 4.5, ((x + 0.099) / 1.099) ** (1 / 0.45))


def encode709(x):
    x = np.maximum(x, 0)
    return np.where(x < 0.018, x * 4.5, 1.099 * x ** 0.45 - 0.099)


def brighten(rgb, stops):
    """Fixed exposure with a white-preserving shoulder, identical for A and B.

    No frame-dependent histogram matching, auto white balance or sharpening.
    Restore black as black; keep the source's changing lighting.
    """
    lin = linear709(np.clip(rgb, 0, 1))
    y = lin @ LUMA
    gain = 2 ** stops
    scale = gain / (1 + (gain - 1) * y)
    return np.clip(encode709(lin * scale[..., None]), 0, 1)


def clean_chroma(rgb):
    """Common edge-guided color cleanup for both experimental engines.

    Broad color blotches survive a small denoising kernel in compressed video.
    Guide their smoothing with luminance while leaving luminance itself intact.
    This fixed filter is deliberately independent of frame histograms.
    """
    yuv = cv2.cvtColor(np.ascontiguousarray(rgb, dtype=np.float32), cv2.COLOR_RGB2YCrCb)
    guide = yuv[..., 0]
    mean = lambda x: cv2.boxFilter(x, -1, (21, 21), borderType=cv2.BORDER_REFLECT_101)
    mi = mean(guide)
    vi = np.maximum(mean(guide * guide) - mi * mi, 0)
    for channel in [1, 2]:
        c = yuv[..., channel]
        mc = mean(c)
        slope = (mean(guide * c) - mi * mc) / (vi + 0.0006)
        intercept = mc - slope * mi
        filtered = mean(slope) * guide + mean(intercept)
        yuv[..., channel] = 0.15 * c + 0.85 * filtered
    return np.clip(cv2.cvtColor(yuv, cv2.COLOR_YCrCb2RGB), 0, 1)


def window_frames(path, start, duration, radius):
    """Bounded source frame window, with real timestamps and off-range context."""
    container = av.open(str(path))
    stream = container.streams.video[0]
    container.seek(max(0, int((start - 1) / float(stream.time_base))), stream=stream)
    frames, indices = deque(), deque()
    next_index = 0
    finished = False
    for frame in container.decode(stream):
        pts = float(frame.time)
        if pts < max(0, start - 0.7):
            continue
        sample = (pts, frame.to_ndarray(format='rgb24').astype(np.float32) / 255)
        if not frames and pts >= start:
            for k in range(-radius, 0):
                frames.append(sample); indices.append(k)
        frames.append(sample)
        indices.append(next_index)
        next_index += 1
        if len(frames) < 2 * radius + 1:
            continue
        if start <= frames[radius][0] < start + duration - 1e-7:
            yield indices[radius], list(frames), radius
        elif frames[radius][0] >= start + duration:
            finished = True
            break
        frames.popleft(); indices.popleft()
    if not finished:
        # End-of-file: hold the last sample only for missing future context.
        while frames and len(frames) > radius:
            if start <= frames[radius][0] < start + duration - 1e-7:
                padded = list(frames)
                padded += [padded[-1]] * (2 * radius + 1 - len(padded))
                yield indices[radius], padded, radius
            frames.popleft(); indices.popleft()
    container.close()


class Neural:
    def __init__(self, directory, checkpoint, noise, ensemble=False):
        import torch
        self.torch = torch
        torch.set_num_threads(4)
        spec = importlib.util.spec_from_file_location('night_fastdvdnet', directory / 'models.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.device = 'mps' if torch.backends.mps.is_available() else 'cpu'
        self.dtype = torch.float16 if self.device == 'mps' else torch.float32
        self.model = module.FastDVDnet().eval()
        state = torch.load(checkpoint, map_location='cpu', weights_only=True)
        self.model.load_state_dict({k.removeprefix('module.'): v for k, v in state.items()})
        self.model.to(self.device, dtype=self.dtype)
        self.noise = noise / 255
        self.first_stage = {}
        self.ensemble = ensemble

    def __call__(self, index, frames, middle):
        torch = self.torch
        five = frames[middle - 2:middle + 3]
        h, w = five[0][1].shape[:2]
        # Pad full frames to network stride, not to a resized inference proxy.
        with torch.inference_mode():
            x = [torch.from_numpy(np.ascontiguousarray(f[1].transpose(2, 0, 1)))
                 .unsqueeze(0).to(self.device, dtype=self.dtype) for f in five]
            x = [torch.nn.functional.pad(f, (0, -w % 4, 0, -h % 4), mode='reflect') for f in x]
            if self.ensemble:
                x = [torch.cat([f, f.flip(-1), f.flip(-2), f.flip((-1, -2))], dim=0) for f in x]
            noise = torch.full((x[0].shape[0], 1, x[0].shape[-2], x[0].shape[-1]), self.noise,
                               device=self.device, dtype=self.dtype)
            # Exactly reuse the same first-stage operations from the original
            # network; each interior three-frame group appears three times.
            for k in range(3):
                key = index + k - 1
                if key not in self.first_stage:
                    self.first_stage[key] = self.model.temp1(x[k], x[k + 1], x[k + 2], noise)
            out = self.model.temp2(*(self.first_stage[index + k - 1] for k in range(3)), noise)
            if self.ensemble:
                out = ((out[0:1] + out[1:2].flip(-1) + out[2:3].flip(-2) + out[3:4].flip((-1, -2))) * 0.25)
            self.first_stage = {k: v for k, v in self.first_stage.items() if k >= index}
            out = out[0, :, :h, :w].float().cpu().numpy().transpose(1, 2, 0)
        if not np.isfinite(out).all():
            raise RuntimeError('Non-finite neural output')
        return np.clip(out, 0, 1)


class Classical:
    def __init__(self, noise):
        self.noise = noise / 255
        cv2.setNumThreads(4)
        self.flow = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
        self.flow.setFinestScale(0)
        self.flow.setGradientDescentIterations(25)
        self.flow.setVariationalRefinementIterations(5)
        self.guides = {}
        self.linear = {}
        self.flows = {}

    def guide(self, index, rgb):
        if index not in self.guides:
            h, w = rgb.shape[:2]
            y = cv2.resize(rgb @ LUMA, (w // 4, h // 4), interpolation=cv2.INTER_AREA)
            y = cv2.GaussianBlur(y, (0, 0), 0.65)
            self.guides[index] = np.uint8(np.clip(np.sqrt(y) * 255, 0, 255))
        return self.guides[index]

    def __call__(self, index, frames, middle):
        rgb = frames[middle][1]
        h, w = rgb.shape[:2]
        guide = self.guide(index, rgb)
        gh, gw = guide.shape
        gx, gy = np.meshgrid(np.arange(gw, dtype=np.float32), np.arange(gh, dtype=np.float32))
        xx, yy = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
        target = cv2.GaussianBlur(rgb, (0, 0), 1.2)
        for n, (_, neighbor) in enumerate(frames):
            key = index + n - middle
            if key not in self.linear:
                self.linear[key] = linear709(neighbor)
        accum = self.linear[index].copy()
        total = np.ones((h, w), dtype=np.float32)
        for n, (_, neighbor) in enumerate(frames):
            if n == middle:
                continue
            other = self.guide(index + n - middle, neighbor)
            # Abrupt lighting changes and cuts are not extra observations of
            # the same exposure. Reject before dense matching.
            if np.mean(np.abs(other.astype(np.float32) - guide)) > 22:
                continue
            key = index + n - middle
            for a, b, ga, gb in [(index, key, guide, other), (key, index, other, guide)]:
                if (a, b) not in self.flows:
                    self.flows[a, b] = self.flow.calc(ga, gb, None)
            forward = self.flows[index, key]
            reverse = self.flows[key, index]
            mx, my = gx + forward[..., 0], gy + forward[..., 1]
            back = cv2.remap(reverse, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
            error = np.linalg.norm(forward + back, axis=2)
            confidence = np.exp(-((error / 0.8) ** 2))
            confidence *= ((mx >= 1) & (mx < gw - 2) & (my >= 1) & (my < gh - 2))
            flow = cv2.resize(forward, (w, h), interpolation=cv2.INTER_LINEAR)
            sx, sy = xx + flow[..., 0] * w / gw, yy + flow[..., 1] * h / gh
            warped = cv2.remap(neighbor, sx, sy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
            difference = cv2.GaussianBlur(warped, (0, 0), 1.2) - target
            difference = np.mean(difference * difference, axis=2)
            confidence = cv2.resize(confidence, (w, h), interpolation=cv2.INTER_LINEAR)
            confidence *= np.exp(-difference / max((self.noise * 1.5) ** 2, 0.000025))
            confidence *= np.exp(-0.5 * ((n - middle) / 3) ** 2)
            aligned_linear = cv2.remap(self.linear[key], sx, sy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
            accum += aligned_linear * confidence[..., None]
            total += confidence
        fused = np.clip(encode709(accum / total[..., None]), 0, 1)
        # Shrink small local residuals, preserving high-contrast texture. Chroma
        # receives more cleanup; motion never falls back to unaligned averaging.
        yuv = cv2.cvtColor(fused, cv2.COLOR_RGB2YCrCb)
        small = cv2.GaussianBlur(yuv, (0, 0), 0.85)
        variance = np.maximum(cv2.GaussianBlur((yuv - small) ** 2, (0, 0), 2), 1e-8)
        noise2 = (self.noise ** 2) / total[..., None]
        channel_scale = np.array([0.7, 2.5, 2.5], dtype=np.float32)
        keep = np.clip(1 - noise2 * channel_scale / variance, 0, 1)
        cleaned = small + keep * (yuv - small)
        self.guides = {k: v for k, v in self.guides.items() if k >= index - middle}
        self.linear = {k: v for k, v in self.linear.items() if k >= index - middle}
        self.flows = {k: v for k, v in self.flows.items() if min(k) >= index - middle}
        return np.clip(cv2.cvtColor(cleaned, cv2.COLOR_YCrCb2RGB), 0, 1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('source', type=Path)
    p.add_argument('destination', type=Path)
    p.add_argument('--engine', choices=['neural', 'classical', 'exposure'], required=True)
    p.add_argument('--start', type=float, default=0)
    p.add_argument('--duration', type=float, default=15)
    p.add_argument('--stops', type=float, default=2.5)
    p.add_argument('--noise', type=float, default=6)
    p.add_argument('--model-directory', type=Path)
    p.add_argument('--checkpoint', type=Path)
    p.add_argument('--still', action='store_true')
    p.add_argument('--pre-lift', action='store_true', help='Experimental model-domain adaptation: common exposure curve before denoising')
    p.add_argument('--ensemble', action='store_true', help='Four reflected neural inferences averaged back in original coordinates')
    p.add_argument('--chroma-cleanup', action='store_true')
    a = p.parse_args()
    assert a.source.resolve() != a.destination.resolve()
    a.destination.parent.mkdir(parents=True, exist_ok=True)
    if a.destination.exists():
        raise FileExistsError(a.destination)
    engine = Neural(a.model_directory, a.checkpoint, a.noise, a.ensemble) if a.engine == 'neural' else Classical(a.noise) if a.engine == 'classical' else lambda i, f, m: f[m][1]
    records, encoder, stream = [], None, None
    lifted = {}
    started = time.time()
    radius = 4 if a.engine == 'classical' else 2
    for index, frames, middle in window_frames(a.source, a.start, a.duration, radius):
        before = time.time()
        if a.pre_lift:
            for n, (pts, rgb) in enumerate(frames):
                key = index + n - middle
                if key not in lifted:
                    lifted[key] = brighten(rgb, a.stops)
            adapted = [(pts, lifted[index + n - middle]) for n, (pts, _) in enumerate(frames)]
            restored = engine(index, adapted, middle)
            lifted = {k: v for k, v in lifted.items() if k >= index - middle}
        else:
            restored = brighten(engine(index, frames, middle), a.stops)
        if a.chroma_cleanup:
            restored = clean_chroma(restored)
        pts = frames[middle][0]
        if a.still:
            from PIL import Image
            Image.fromarray(np.uint8(np.round(restored * 255))).save(a.destination)
            records.append({'sourceTime': pts, 'seconds': time.time() - before})
            break
        if encoder is None:
            encoder = av.open(str(a.destination), 'w')
            stream = encoder.add_stream('hevc_videotoolbox', rate=30)
            stream.width, stream.height = restored.shape[1], restored.shape[0]
            stream.pix_fmt = 'p010le'
            stream.bit_rate = 18_000_000
            stream.codec_context.color_primaries = 1
            stream.codec_context.color_trc = 1
            stream.codec_context.colorspace = 1
            stream.codec_context.color_range = 1
            stream.time_base = Fraction(1, 240000)
            stream.codec_context.time_base = Fraction(1, 240000)
            stream.codec_context.codec_tag = 'hvc1'
        frame = av.VideoFrame.from_ndarray(np.uint16(np.round(restored * 65535)), format='rgb48le')
        frame = frame.reformat(format='p010le', src_colorspace='ITU709', dst_colorspace='ITU709')
        frame.pts = round((pts - a.start) * 240000)
        frame.time_base = Fraction(1, 240000)
        for packet in stream.encode(frame):
            encoder.mux(packet)
        records.append({'sourceTime': pts, 'seconds': time.time() - before})
        if len(records) % 30 == 0:
            print(json.dumps({'engine': a.engine, 'frames': len(records), 'sourceTime': pts, 'elapsed': time.time() - started}), flush=True)
    if encoder:
        for packet in stream.encode():
            encoder.mux(packet)
        encoder.close()
    if not records:
        raise RuntimeError('No source frames found')
    report = {'engine': a.engine, 'source': str(a.source), 'sourceStart': a.start,
              'requestedDuration': a.duration, 'stops': a.stops, 'noiseCodeValues': a.noise, 'preLift': a.pre_lift,
              'ensemble': a.ensemble, 'chromaCleanup': a.chroma_cleanup,
              'seconds': time.time() - started, 'frames': records, 'audio': 'not included in intermediate'}
    if a.checkpoint:
        report['checkpointSHA256'] = hashlib.sha256(a.checkpoint.read_bytes()).hexdigest()
    a.destination.with_suffix(a.destination.suffix + '.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'frames'}), flush=True)


if __name__ == '__main__':
    main()
