#include "VoiceFixerDSP.h"
#include <algorithm>
#include <cmath>
#include <complex>
#include <vector>
namespace {
using Complex = std::complex<float>;
constexpr double pi = 3.14159265358979323846;
void fft(std::vector<Complex>& values, bool inverse) {
    const int size = int(values.size());
    for (int i = 1, j = 0; i < size; i++) {
        int bit = size >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(values[i], values[j]);
    }
    for (int width = 2; width <= size; width <<= 1) {
        double angle = (inverse ? 2 : -2) * pi / width;
        Complex step(std::cos(angle), std::sin(angle));
        for (int begin = 0; begin < size; begin += width) {
            Complex rotation(1, 0);
            for (int j = 0; j < width / 2; j++) {
                Complex even = values[begin + j], odd = rotation * values[begin + j + width / 2];
                values[begin + j] = even + odd;
                values[begin + j + width / 2] = even - odd;
                rotation *= step;
            }
        }
    }
    if (inverse) for (auto& value : values) value /= size;
}

}
int yr_voicefixer_features(const float *audio, const float *bank, float *mel) {
    try {
        constexpr int n = 2048, bins = 1025, samples = 112455;
        std::vector<Complex> spectrum(n);
        std::vector<float> magnitude(bins);
        for (int t = 0; t < 256; t++) {
            for (int i = 0; i < n; i++) {
                int j = t * 441 + i - n / 2;
                if (j < 0) j = -j;
                if (j >= samples) j = 2 * samples - 2 - j;
                spectrum[i] = Complex(audio[j] * float(0.5 * (1 - std::cos(2 * pi * i / n))), 0);
            }
            fft(spectrum, false);
            for (int f = 0; f < bins; f++) magnitude[f] = std::sqrt(std::max(1e-8f, std::norm(spectrum[f])));
            for (int m = 0; m < 128; m++) {
                float sum = 0;
                for (int f = 0; f < bins; f++) sum += magnitude[f] * bank[f * 128 + m];
                mel[t * 128 + m] = sum;
            }
        }
        return 1;
    } catch (...) { return 0; }
}
