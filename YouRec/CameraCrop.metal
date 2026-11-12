#include <metal_stdlib>
using namespace metal;

// Sample at fractional sensor coordinates; a clean-aperture transfer may round
// its origin to the chroma grid and hold or jump during a slow camera move.
kernel void cameraSubpixelCrop(texture2d<float, access::sample> source [[texture(0)]],
                               texture2d<float, access::write> output [[texture(1)]],
                               constant float4 &matrix [[buffer(0)]],
                               constant uint &tenBit [[buffer(1)]],
                               constant float2 &origin [[buffer(2)]],
                               uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(p) + 0.5f) / float2(output.get_width(), output.get_height());
    float4 color = source.sample(linear, origin + float2(dot(matrix.xy, uv), dot(matrix.zw, uv)));
    // Bi-planar 10-bit camera samples occupy the high ten bits in each word.
    if (tenBit) color = round(color * (65535.0f / 64.0f)) * (64.0f / 65535.0f);
    output.write(color, p);
}
