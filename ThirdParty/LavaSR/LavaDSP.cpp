#include "LavaDSP.h"
#include <algorithm>
#include <cmath>
#include <complex>
#include <vector>

namespace {
constexpr int fftSize = 2048, hop = 512, frames = 375, length = 192000;
constexpr int bins = fftSize / 2 + 1, padding = (fftSize - hop) / 2;
constexpr double pi = 3.14159265358979323846;
using Complex = std::complex<float>;

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

float hzToMel(float hz) {
    return hz < 1000 ? hz * 3 / 200 : 15 + std::log(hz / 1000) * 27 / std::log(6.4f);
}
float melToHz(float mel) {
    return mel < 15 ? mel * 200 / 3 : 1000 * std::exp((mel - 15) * std::log(6.4f) / 27);
}
struct Tables {
    std::vector<float> window, bank;
    Tables(): window(fftSize), bank(80 * bins) {
        for (int i = 0; i < fftSize; i++) window[i] = 0.5f * (1 - std::cos(2 * pi * i / fftSize));
        float edges[82];
        for (int i = 0; i < 82; i++) edges[i] = melToHz(hzToMel(8000) * i / 81);
        // The published v2 checkpoint uses a 44100-Hz Slaney filterbank even
        // while its waveform is 48 kHz. Preserve that training convention.
        for (int m = 0; m < 80; m++) {
            for (int f = 0; f < bins; f++) {
                float hz = float(f) * 44100 / fftSize;
                float up = (hz - edges[m]) / (edges[m + 1] - edges[m]);
                float down = (edges[m + 2] - hz) / (edges[m + 2] - edges[m + 1]);
                bank[m * bins + f] = std::max(0.f, std::min(up, down)) * 2 / (edges[m + 2] - edges[m]);
            }
        }
    }
};
const Tables& tables() { static const Tables value; return value; }
}

int yr_lava_features(const float *audio, float *mel) {
    try {
        const auto& t = tables();
        std::vector<Complex> spectrum(fftSize);
        std::vector<float> magnitudes(bins);
        for (int frame = 0; frame < frames; frame++) {
            for (int i = 0; i < fftSize; i++) {
                int index = frame * hop + i - padding;
                if (index < 0) index = -index;
                if (index >= length) index = 2 * length - 2 - index;
                spectrum[i] = Complex(audio[index] * t.window[i], 0);
            }
            fft(spectrum, false);
            for (int f = 0; f < bins; f++) magnitudes[f] = std::abs(spectrum[f]);
            for (int m = 0; m < 80; m++) {
                float sum = 0;
                for (int f = 0; f < bins; f++) sum += t.bank[m * bins + f] * magnitudes[f];
                mel[m * frames + frame] = std::log(std::max(1e-5f, sum));
            }
        }
        return 1;
    } catch (...) { return 0; }
}

int yr_lava_reconstruct(const float *real, const float *imaginary, float *audio) {
    try {
        const auto& t = tables();
        constexpr int paddedLength = (frames - 1) * hop + fftSize;
        std::vector<float> output(paddedLength, 0), envelope(paddedLength, 0);
        std::vector<Complex> spectrum(fftSize);
        for (int frame = 0; frame < frames; frame++) {
            for (int f = 0; f < bins; f++) {
                spectrum[f] = Complex(real[f * frames + frame], (f == 0 || f == fftSize / 2) ? 0 : imaginary[f * frames + frame]);
                if (f > 0 && f < fftSize / 2) spectrum[fftSize - f] = std::conj(spectrum[f]);
            }
            fft(spectrum, true);
            for (int i = 0; i < fftSize; i++) {
                int index = frame * hop + i;
                output[index] += spectrum[i].real() * t.window[i];
                envelope[index] += t.window[i] * t.window[i];
            }
        }
        for (int i = 0; i < length; i++) audio[i] = output[i + padding] / std::max(1e-8f, envelope[i + padding]);
        return 1;
    } catch (...) { return 0; }
}

int yr_lava_merge(const float *original, const float *restored, float *output) {
    try {
        // Preserve the original low/mid band. Only restore upper frequencies,
        // with a smooth complementary crossover and no time-domain delay.
        constexpr int size = 262144;
        std::vector<Complex> difference(size, Complex(0, 0));
        for (int i = 0; i < length; i++) difference[i] = Complex(restored[i] - original[i], 0);
        fft(difference, false);
        for (int i = 0; i < size; i++) {
            float hz = float(std::min(i, size - i)) * 48000 / size;
            float t = std::clamp((hz - 4000) / 2000, 0.f, 1.f);
            difference[i] *= t * t * (3 - 2 * t);
        }
        fft(difference, true);
        for (int i = 0; i < length; i++) output[i] = original[i] + difference[i].real();
        return 1;
    } catch (...) { return 0; }
}
