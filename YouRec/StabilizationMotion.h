#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Motion maps previous -> current, in centered, top-left image coordinates.
typedef struct {
    double x, y, angle, logScale;
    double inlierRatio;
    int inliers;
    int valid;
} YRMotion;
YRMotion yr_estimate_motion(const uint8_t *previous, const uint8_t *current, int width, int height);
#ifdef __cplusplus
}
#endif
