"""Reproducible LavaSR v2 network conversion; DSP remains outside Core ML.

Use Python 3.12, torch/torchaudio 2.7.0, coremltools 9.0, vocos 0.1.0.
Upstream checkpoint SHA is checked before loading with weights_only=True.
Usage: python scripts/convert-lavasr.py weights.bin config.yaml output.mlpackage
"""
import hashlib
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import yaml
from vocos import Vocos

weights, config, destination = map(Path, sys.argv[1:])
expected = "d100db961b2c125d77a52a12215c689e44cd9926a72f117513395b7e25e6de12"
assert hashlib.sha256(weights.read_bytes()).hexdigest() == expected
torch.set_num_threads(4)
torch.manual_seed(0)
configuration = yaml.safe_load(config.read_text())
# vocos 0.1.0 lacks the fork's frontend constructor extensions. The frontend is
# not exported; the native DSP implements the exact published Slaney bank.
for key in ["f_min", "f_max", "norm", "mel_scale"]:
    configuration["feature_extractor"]["init_args"].pop(key, None)
compatible = destination.parent / "conversion-config.yaml"
compatible.write_text(yaml.safe_dump(configuration))
vocos = Vocos.from_hparams(str(compatible))
vocos.load_state_dict(torch.load(weights, map_location="cpu", weights_only=True))


class SpectralNetwork(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = vocos.backbone
        self.head = vocos.head.out

    def forward(self, mel):
        spectrum = self.head(self.backbone(mel)).transpose(1, 2)
        magnitude, phase = spectrum.chunk(2, dim=1)
        magnitude = torch.clamp(torch.exp(magnitude), max=1000)
        return magnitude * torch.cos(phase), magnitude * torch.sin(phase)


network = SpectralNetwork().eval()
# 192000 samples, 375 mel frames: four seconds at 48 kHz. Fixed-size chunks
# permit predictable memory, overlap/context cropping, and bounded cancellation.
example = torch.randn(1, 80, 375) - 5
with torch.inference_mode():
    traced = torch.jit.trace(network, example)
    reference = network(example)
model = ct.convert(traced, inputs=[ct.TensorType(name="mel", shape=example.shape)],
                   outputs=[ct.TensorType(name="real"), ct.TensorType(name="imaginary")],
                   minimum_deployment_target=ct.target.iOS17,
                   compute_precision=ct.precision.FLOAT32,
                   compute_units=ct.ComputeUnit.CPU_AND_GPU)
model.short_description = "LavaSR v2 spectral restoration, fixed 4-second context"
model.author = "Yatharth Sharma; YouRec Core ML conversion"
model.license = "Apache-2.0"
model.user_defined_metadata["upstream_weights_sha256"] = expected
model.save(str(destination))
prediction = model.predict({"mel": example.numpy()})
errors = {name: float(np.max(np.abs(prediction[name] - value.numpy())))
          for name, value in zip(["real", "imaginary"], reference)}
print(json.dumps({"conversion": "complete", "max_absolute_error": errors}))
