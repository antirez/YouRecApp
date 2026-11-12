#pragma once

// Each instance owns independent model/channel state. Samples are normalized
// Float32 at 48 kHz. Exactly 480 samples are consumed/produced per call.
void *yr_denoiser_create(void);
void yr_denoiser_destroy(void *state);
void yr_denoiser_process(void *state, const float *input, float *output);
// Speech probability for one channel of a 10 ms interleaved normalized frame.
float yr_speech_probability(void *state, const float *input, int stride);
