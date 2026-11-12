# RNNoise native baseline

Upstream: https://github.com/xiph/rnnoise
Tag v0.1, commit `cdf196b1e9de2f8ff1003328ebf9a4316477429d`.
The embedded pretrained weights are unchanged. The two undefined null-pointer
assertions in upstream rnn.c are replaced with abort(); all other source is unchanged.
The BSD license is in COPYING. YouRecDenoiser.c/.h are the local adapter.

This is a reproducible integration baseline, not a claim that the 2017 model is
the best available model. It suppresses background noise; it does not identify a
particular speaker or promise dereverberation or studio microphone emulation.
Each stereo channel is processed independently. The offline adapter compensates
the 480-sample overlap/add delay and mixes against the corresponding dry samples.
