"""Build the bundled VoiceFixer Core ML model from pinned upstream artifacts.

Python 3.12; torch 2.7.0; coremltools 9.0; numpy 2.2.6; torchlibrosa 0.1.0.
Also needs librosa, scipy, matplotlib, progressbar and pyyaml.
Usage: python scripts/convert-voicefixer.py /path/to/conversion-cache
Weights are verified before PyTorch deserialization (weights_only=True).
No model binaries are committed to Git. The output is ~200 MB, bundled in iOS.
"""
import hashlib, os, subprocess, sys, urllib.request
from pathlib import Path
root = Path(__file__).resolve().parent.parent
cache = Path(sys.argv[1]).resolve(); cache.mkdir(parents=True, exist_ok=True)
source = cache / 'upstream'
commit = 'aae2253c85f97a87b844b6832384de249c23ab37'
if not source.exists(): subprocess.run(['git', 'clone', 'https://github.com/haoheliu/voicefixer.git', str(source)], check=True)
subprocess.run(['git', '-C', str(source), 'checkout', '--detach', commit], check=True)
files = [
 ('vf.ckpt', 'analysis_module/checkpoints/vf.ckpt', '748411b70089cadf34a6c11054f95f3a454e614af562c23b13a82f6cb413109f'),
 ('model.ckpt-1490000_trimed.pt', 'synthesis_module/44100/model.ckpt-1490000_trimed.pt', '9410d0b528c10a251ae947bd299d1939b0b3247df680c81c4164e94f5d87dc45')]
for name, relative, digest in files:
 path = cache / '.cache/voicefixer' / relative; path.parent.mkdir(parents=True, exist_ok=True)
 if not path.exists(): urllib.request.urlretrieve('https://zenodo.org/records/5600188/files/' + name + '?download=1', path)
 if hashlib.sha256(path.read_bytes()).hexdigest() != digest: raise RuntimeError('Invalid upstream checkpoint: ' + name)
# Upstream uses expanduser('~') to locate the checkpoints. Isolate its cache
# without modifying HOME, installing files in the user's cache or patching source.
expand = os.path.expanduser
os.path.expanduser = lambda p: str(cache) if str(p) == '~' else expand(p)
sys.path.insert(0, str(source))
import coremltools as ct
import numpy as np
import torch
from voicefixer import VoiceFixer
assert torch.__version__.startswith('2.7.'), 'Use pinned torch 2.7.0 (safe weights-only loading by default)'
torch.set_num_threads(4); torch.manual_seed(0)
model = VoiceFixer().eval()
class Network(torch.nn.Module):
 def __init__(self):
  super().__init__(); self.generator = model._model.generator; self.vocoder = model._model.vocoder
 def forward(self, mel):
  restored = torch.pow(10, torch.clamp(self.generator(mel, mel)['mel'], max=5))
  return self.vocoder(restored).squeeze(1)
network = Network().eval()
example = torch.rand(1, 1, 256, 128)
with torch.inference_mode(): traced = torch.jit.trace(network, example, check_trace=False)
converted = ct.convert(traced, inputs=[ct.TensorType(name='mel', shape=example.shape, dtype=np.float32)], outputs=[ct.TensorType(name='audio', dtype=np.float32)],
 minimum_deployment_target=ct.target.iOS17,
 compute_precision=ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in {'log','pow','clip','real_div','gru'}),
 compute_units=ct.ComputeUnit.CPU_AND_GPU)
destination = root / 'ThirdParty/VoiceFixer'
converted.save(str(destination / 'VoiceFixer.mlpackage'))
model._model.mel.fb.detach().numpy().astype('<f4').tofile(destination / 'VoiceFixer-Mel.bin')
expected = '67971970d18c06c1220dc63df11aa0186f787dc961c829dcd1624dad3d612360'
actual = hashlib.sha256((destination / 'VoiceFixer.mlpackage/Data/com.apple.CoreML/weights/weight.bin').read_bytes()).hexdigest()
if actual != expected: raise RuntimeError('Conversion differs from validated weights; review parity and update provenance before shipping: '+actual)
print('Converted and verified VoiceFixer:', actual)
