// Phase 2 live-preview presentation kernel.
//
// Compiled together with Spike/MetalSources/Shaders.metal and the three slider
// groups' files into ONE MTLLibrary by MetalContext (see
// MetalContext.shaderSources). Still one compile per process, which is what
// RenderGraph.prewarm() relies on.
//
// This file has NO retouch maths in it and must never get any. It is the last
// step of the interactive path only: the render graph has already produced the
// edited picture at preview resolution, and this pass copies that picture into
// the drawable of an MTKView at whatever position and scale the canvas viewport
// (zoom / pan) currently asks for, filling the rest with the canvas background.
//
// Conventions, same as the other files:
//   image space = pixels, origin top-left, y down;
//   value space = gamma-encoded sRGB, 0…1 (RenderQuality.pixelSpace, ADR-0007).
//
// **Why the values go into the drawable unchanged.** The graph works in
// sRGB-*encoded* values, and LivePreviewRenderer configures the layer as
// `bgra8Unorm` (NOT `_srgb`) with a plain sRGB colour space, so a value written
// here is displayed as that sRGB code value. Writing to a `bgra8Unorm_srgb`
// drawable instead would apply the encoding a second time and wash the picture
// out; that combination is the classic "canvas looks faded" bug and is pinned by
// LivePreviewRendererTests.presentIsExactAtOneToOne, which requires the
// round trip through this kernel to be exact at 1:1 scale.

#include <metal_stdlib>
using namespace metal;

struct RPPreviewPresentParams {
    uint2 destinationSize;
    // Where the image goes inside the destination, in destination pixels.
    float2 origin;
    float2 size;
    // What to write outside that rectangle.
    float4 background;
    // 1 = sample with a linear filter (zoomed out / fractional scale),
    // 0 = nearest neighbour (1:1 and integer zoom-in, so pixel peeping shows
    // the pixels rather than a blur).
    uint linearFilter;
};

kernel void rp_preview_present(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant RPPreviewPresentParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.destinationSize.x || gid.y >= prm.destinationSize.y) { return; }

    // Pixel centre, so a 1:1 placement lands exactly on source texel centres.
    float2 centre = float2(gid) + 0.5f;
    float2 uv = (centre - prm.origin) / max(prm.size, float2(1e-6f));

    float4 out = prm.background;
    if (uv.x >= 0.0f && uv.x <= 1.0f && uv.y >= 0.0f && uv.y <= 1.0f) {
        constexpr sampler linearSampler(
            coord::normalized, filter::linear, mip_filter::none, address::clamp_to_edge);
        constexpr sampler nearestSampler(
            coord::normalized, filter::nearest, mip_filter::none, address::clamp_to_edge);
        float3 rgb = prm.linearFilter != 0u
            ? source.sample(linearSampler, uv).rgb
            : source.sample(nearestSampler, uv).rgb;
        out = float4(rgb, 1.0f);
    }
    destination.write(out, gid);
}
