#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// 112455 mono samples at 44100 Hz -> [256,128] magnitude mel features.
// bank is the upstream HTK matrix, row-major [1025,128].
int yr_voicefixer_features(const float *audio, const float *bank, float *mel);
#ifdef __cplusplus
}
#endif
