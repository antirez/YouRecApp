#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Fixed 48 kHz, four-second contexts. Mel layout [80][375]; spectra
// [1025][375]. Functions return zero on failure and contain C++ exceptions.
int yr_lava_features(const float *audio, float *mel);
int yr_lava_reconstruct(const float *real, const float *imaginary, float *audio);
int yr_lava_merge(const float *original, const float *restored, float *output);
#ifdef __cplusplus
}
#endif
