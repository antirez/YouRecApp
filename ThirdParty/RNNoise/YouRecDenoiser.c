#include "YouRecDenoiser.h"
#include "include/rnnoise.h"
#include <pthread.h>

// v0.1 initializes shared FFT tables lazily. Serialize instance construction
// and warm-up, including the first processing call, before publishing a state.
static pthread_mutex_t initialization_lock = PTHREAD_MUTEX_INITIALIZER;
void *yr_denoiser_create(void) {
    pthread_mutex_lock(&initialization_lock);
    DenoiseState *state = rnnoise_create();
    if (state) {
        float zeros[480] = {0}, output[480];
        rnnoise_process_frame(state, output, zeros);
    }
    pthread_mutex_unlock(&initialization_lock);
    return state;
}
void yr_denoiser_destroy(void *state) { if (state) rnnoise_destroy(state); }
float yr_speech_probability(void *state, const float *input, int stride) {
    float scaled[480], unused[480];
    for (int i = 0; i < 480; i++) scaled[i] = input[i * stride] * 32768.f;
    return rnnoise_process_frame(state, unused, scaled);
}
void yr_denoiser_process(void *state, const float *input, float *output) {
    float scaled[480], processed[480];
    for (int i = 0; i < 480; i++) scaled[i] = input[i] * 32768.f;
    rnnoise_process_frame(state, processed, scaled);
    for (int i = 0; i < 480; i++) output[i] = processed[i] / 32768.f;
}
