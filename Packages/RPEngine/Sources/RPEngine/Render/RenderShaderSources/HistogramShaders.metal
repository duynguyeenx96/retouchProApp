// Phase 6 — the canvas histogram ("biểu đồ màu", docs/ADR-0024).
//
// Compiled together with the other render kernels into one MTLLibrary by
// MetalContext — see its doc comment. This file must not redeclare anything
// Shaders.metal / SkinShaders.metal already declares; it *uses* SkinShaders'
// `kRPLuma`, so it is concatenated after that file.
//
// Two kernels over the graph's **output** texture:
//
//   rp_histogram_clear       zero the 1024 device counters (256 bins x 4);
//   rp_histogram_accumulate  one thread per sampled pixel, binning R, G, B and
//                            luma.
//
// ## What is binned, and why it is the encoded value
//
// The pipeline's working texture is rgba16Float holding **sRGB-encoded** values
// (`RenderQuality.pixelSpace`, ADR-0007) — the same code values that go to the
// drawable and therefore the same numbers the user is looking at. The bucket is
// `min(floor(v * 256), 255)` on that value, clamped to [0, 1] first. That is
// what every photo application's histogram shows: a display-referred
// distribution, not linear light. Binning linear light instead would pile most
// of a normally-exposed frame into the bottom fifth of the plot and the reading
// would not match the picture.
//
// Values outside [0, 1] exist in an rgba16Float texture (a slider can push a
// highlight past 1.0). They are clamped into the end bins rather than dropped,
// so a clipped highlight shows up as the spike at 255 a photographer expects.
//
// ## Why a threadgroup histogram and not 4 device atomics per pixel
//
// 256 bins is small enough that a frame's worth of pixels contends hard on a
// handful of counters — a flat grey area is 2.8 M increments on *one* address.
// So each threadgroup keeps its own copy in threadgroup memory (1024 x 4 B =
// 4 KB, well under the 32 KB limit), and merges it into the device buffer with
// at most 1024 atomic adds per threadgroup. Contention then scales with the
// number of threadgroups, not the number of pixels.

#include <metal_stdlib>
using namespace metal;

/// 256 bins x 4 channels (R, G, B, luma), laid out channel-major:
/// `bins[channel * 256 + bucket]`. Must match `ImageHistogram.binCount` and
/// `ImageHistogram.channelCount` in Histogram.swift.
constexpr constant uint kRPHistogramBins = 256;
constexpr constant uint kRPHistogramChannels = 4;
constexpr constant uint kRPHistogramSlots = kRPHistogramBins * kRPHistogramChannels;

/// Must match `HistogramParams` in Histogram.swift.
struct RPHistogramParams {
    /// Size of the texture being read, in pixels.
    uint2 size;
    /// Pixel stride. `(1, 1)` reads every pixel; `(2, 2)` reads a quarter of
    /// them. The dispatch grid is sized `ceil(size / step)`, so a thread's
    /// pixel is `gid * step`.
    uint2 step;
};

kernel void rp_histogram_clear(
    device atomic_uint *bins [[buffer(0)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= kRPHistogramSlots) { return; }
    atomic_store_explicit(&bins[gid], 0u, memory_order_relaxed);
}

kernel void rp_histogram_accumulate(
    texture2d<float, access::read> source [[texture(0)]],
    device atomic_uint *bins [[buffer(0)]],
    constant RPHistogramParams &prm [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    // uint2, not uint3: MSL requires every grid/threadgroup positional
    // attribute in one kernel's signature to have the same number of
    // components, and `gid` above is a uint2. (`thread_index_in_threadgroup`
    // is inherently scalar and is exempt.)
    uint2 threadsPerGroup [[threads_per_threadgroup]])
{
    threadgroup atomic_uint local[kRPHistogramSlots];

    const uint groupThreads = max(1u, threadsPerGroup.x * threadsPerGroup.y);
    for (uint i = tid; i < kRPHistogramSlots; i += groupThreads) {
        atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const uint2 p = gid * max(prm.step, uint2(1u, 1u));
    if (p.x < prm.size.x && p.y < prm.size.y) {
        const float3 v = clamp(source.read(p).rgb, 0.0, 1.0);
        // `v * 256` then clamp: 1.0 would otherwise land in bin 256.
        const uint3 bucket = min(uint3(v * 256.0), uint3(kRPHistogramBins - 1));
        const float y = clamp(dot(v, kRPLuma), 0.0, 1.0);
        const uint lumaBucket = min(uint(y * 256.0), kRPHistogramBins - 1);

        atomic_fetch_add_explicit(&local[bucket.x], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &local[kRPHistogramBins + bucket.y], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &local[2u * kRPHistogramBins + bucket.z], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &local[3u * kRPHistogramBins + lumaBucket], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint i = tid; i < kRPHistogramSlots; i += groupThreads) {
        const uint count = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (count != 0u) {
            atomic_fetch_add_explicit(&bins[i], count, memory_order_relaxed);
        }
    }
}
