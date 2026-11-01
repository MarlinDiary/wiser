//
//  PathTracer.metal
//  Wiser
//
//  Created by Marlin on 19/10/2026.
//

#include <metal_stdlib>
using namespace metal;
#if !SOFTWARE_RAYS
#include <metal_raytracing>
using namespace metal::raytracing;
#endif

// The scene as light actually travels through it: rays from the eye, through each pixel, to the stones,
// the ground or the sky; and at every surface they meet, light gathered from the sky and the key light,
// blocked by whatever stands in the way, and bounced off the ground and the other stones. Every
// shadow, every bit of shade where the stones meet each other and the ground, and every reflection
// comes from tracing rays against the stones' real shapes. Each frame adds one more sample to every
// pixel, so a still scene settles on the exact picture.

// MARK: Data, as PathTracer.swift lays it out

/// A node of a stone's bounding volumes; see BoundingVolumes.swift.
struct TraceNode {
    packed_float3 lower;
    uint offset;
    packed_float3 upper;
    uint count;
};

/// A stone where it stands now.
struct TraceStone {
    float4x4 toObject;
    float4x4 toWorld;
    /// A sphere around it, in the world: middle and radius.
    float4 bounds;
    /// Where its nodes and its triangles, in the order its leaves list them, begin; which stone it is;
    /// and where its triangles begin in the index list, over three.
    uint nodes;
    uint triangles;
    uint index;
    uint first;
};

struct TraceUniforms {
    // The camera: where it is (meters) and which way its right, up and forward point.
    float4 eye;
    float4 right;
    float4 up;
    float4 forward;
    /// The sky's radiance at the horizon and high up, linear.
    float4 skyHorizon;
    float4 skyTop;
    /// Where the key light is (xyz, toward it) and the cosine of its angular radius (w); its radiance.
    float4 key;
    float4 keyRadiance;
    /// The brighter sky around the key light: its radiance at the middle (rgb) and its angular width (w).
    float4 glow;
    /// Where the glow of brighter sky is brightest (toward it).
    float4 glowCenter;
    /// What an open, level patch of ground receives from the sky and from the key light.
    float4 skyIrradiance;
    float4 keyIrradiance;
    float4 groundAlbedo;
    float4 stoneAlbedo;
    /// The fog bank around the clearing the stones stand in: where it starts and where it's full, from
    /// the stack's middle (meters), how thick it is there (per meter), and its height scale (meters).
    float4 fog;
    /// The light reaching the fog from all around, and how much of what reaches it it scatters.
    float4 fogLight;
    float4 fogAlbedo;
    /// The stack's middle, on the ground.
    float4 stack;
    /// Where in the view (points) the camera looks, and the view's size in pixels.
    float2 center;
    float2 viewSize;
    /// Where in the pixel this sample looks through, from -0.5 to 0.5.
    float2 jitter;
    /// How many points from the middle of the view a ray one unit off straight ahead lands.
    float focal;
    float pixelsPerPoint;
    /// How many samples back each pixel's average carries on from (0 starts over), and a number that
    /// changes every frame.
    uint limit;
    uint frame;
    /// The rows traced this frame, and how many samples each pixel there takes.
    uint regionTop;
    uint regionHeight;
    uint samples;
    /// How many times paths bounce on after the surface the eye sees.
    uint bounces;
    /// How much brighter the sky is overhead than where the view ends, between which elevations it
    /// brightens (radians), and how far the stones' fine relief tilts their surface.
    float zenith;
    float zenithFrom;
    float zenithTo;
    float reliefDepth;
    float roughness;
    float specular;
    float exposure;
    float grainOpacity;
    float isDark;
    /// The columns traced this frame, where only a part of the view is.
    uint regionLeft;
    uint regionWidth;
};

struct Geometry {
    device const TraceNode *nodes;
    device const float4 *triangles;
    device const uint *indices;
    device const float4 *normals;
    device const float4 *tangents;
    device const float4 *bitangents;
    device const float2 *coordinates;
    constant TraceStone *stones;
    device const float4 *positions;
#if !SOFTWARE_RAYS
    /// The stones as the GPU's own ray tracing sees them.
    instance_acceleration_structure scene;
#endif
};

// MARK: Random numbers

static inline uint hashed(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

/// The next random number from 0 to 1 in a stream.
static inline float next(thread uint &state) {
    state = hashed(state);
    return float(state) * (1.0 / 4294967296.0);
}

static inline float2 next2(thread uint &state) {
    float a = next(state);
    return float2(a, next(state));
}

// MARK: Directions

/// Two directions at right angles to `n` and each other.
static inline void basis(float3 n, thread float3 &t, thread float3 &b) {
    float s = n.z >= 0 ? 1.0 : -1.0;
    float a = -1.0 / (s + n.z);
    float c = n.x * n.y * a;
    t = float3(1 + s * n.x * n.x * a, s * c, -s * n.x);
    b = float3(c, s + n.y * n.y * a, -n.y);
}

/// A direction around `n`, more of them the more face on, as light falls on a matte surface.
static inline float3 cosineSample(float3 n, float2 xi) {
    float3 t, b;
    basis(n, t, b);
    float r = sqrt(xi.x), phi = 2 * M_PI_F * xi.y;
    return t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0, 1 - xi.x));
}

/// A direction within `cosMax` of `axis`, every one as likely.
static inline float3 coneSample(float3 axis, float cosMax, float2 xi) {
    float3 t, b;
    basis(axis, t, b);
    float c = 1 - xi.x * (1 - cosMax), s = sqrt(max(0.0, 1 - c * c)), phi = 2 * M_PI_F * xi.y;
    return t * (s * cos(phi)) + b * (s * sin(phi)) + axis * c;
}

// MARK: Tracing

struct Hit {
    float t;
    float2 barycentrics;
    /// The triangle's place in the stones' index list, over three.
    uint triangle;
    /// What's there: 0 to 2 a stone, 3 the ground, -1 nothing (the sky).
    int what;
};

static inline bool box(float3 lower, float3 upper, float3 origin, float3 inverse, float far, thread float &near) {
    float3 a = (lower - origin) * inverse, b = (upper - origin) * inverse;
    float3 low = min(a, b), high = max(a, b);
    near = max(max(low.x, low.y), max(low.z, 0.0));
    return near <= min(min(high.x, high.y), min(high.z, far));
}

/// The nearest of a stone's triangles a ray in the stone's own frame meets before `far`, or, if `any`,
/// whether it meets one at all.
static bool traceStone(float3 origin, float3 direction, thread float &far, thread const Geometry &g,
                       constant TraceStone &stone, bool any, thread Hit &hit) {
    float3 inverse = 1 / select(direction, float3(1e-12), abs(direction) < 1e-12);
    uint stack[44];
    int top = 0;
    uint index = stone.nodes;
    bool found = false;
    while (true) {
        TraceNode node = g.nodes[index];
        if (node.count > 0) {
            for (uint i = 0; i < node.count; i++) {
                uint k = (stone.triangles + node.offset + i) * 3;
                float4 a = g.triangles[k], e1 = g.triangles[k + 1], e2 = g.triangles[k + 2];
                float3 p = cross(direction, e2.xyz);
                float determinant = dot(e1.xyz, p);
                if (abs(determinant) < 1e-14) {
                    continue;
                }
                float reciprocal = 1 / determinant;
                float3 s = origin - a.xyz;
                float u = dot(s, p) * reciprocal;
                if (u < 0 || u > 1) {
                    continue;
                }
                float3 q = cross(s, e1.xyz);
                float v = dot(direction, q) * reciprocal;
                if (v < 0 || u + v > 1) {
                    continue;
                }
                float t = dot(e2.xyz, q) * reciprocal;
                if (t > 1e-6 && t < far) {
                    far = t;
                    found = true;
                    hit.t = t;
                    hit.barycentrics = float2(u, v);
                    hit.triangle = as_type<uint>(a.w);
                    if (any) {
                        return true;
                    }
                }
            }
        } else {
            uint left = stone.nodes + node.offset;
            TraceNode l = g.nodes[left], r = g.nodes[left + 1];
            float nearLeft, nearRight;
            bool hitLeft = box(l.lower, l.upper, origin, inverse, far, nearLeft);
            bool hitRight = box(r.lower, r.upper, origin, inverse, far, nearRight);
            if (hitLeft && hitRight) {
                bool leftFirst = nearLeft <= nearRight;
                stack[top++] = leftFirst ? left + 1 : left;
                index = leftFirst ? left : left + 1;
                continue;
            } else if (hitLeft || hitRight) {
                index = hitLeft ? left : left + 1;
                continue;
            }
        }
        if (top == 0) {
            break;
        }
        index = stack[--top];
    }
    return found;
}

/// Whether a ray might come near stone `k` before `far`: it passes through the sphere around it.
static inline bool mightMeet(float3 origin, float3 direction, float far, constant TraceStone &stone) {
    float3 toMiddle = stone.bounds.xyz - origin;
    float along = dot(toMiddle, direction);
    float apart = length_squared(toMiddle) - along * along;
    float r2 = stone.bounds.w * stone.bounds.w;
    if (apart > r2) {
        return false;
    }
    float chord = sqrt(r2 - apart);
    return along + chord > 0 && along - chord < far;
}

/// What a ray from `origin` toward `direction` meets first, within `far`: a stone, the ground, or
/// nothing. With `any`, it stops at whatever stone it meets first, for shadows.
static Hit trace(float3 origin, float3 direction, float far, thread const Geometry &g, bool any) {
    Hit hit;
    hit.t = far;
    hit.what = -1;
    if (direction.y < -1e-7 && origin.y > 0) {
        float t = -origin.y / direction.y;
        if (t < hit.t) {
            hit.t = t;
            hit.what = 3;
        }
    }
#if !SOFTWARE_RAYS
    ray r(origin, direction, 1e-6, hit.t);
    intersector<triangle_data, instancing> stones;
    stones.assume_geometry_type(geometry_type::triangle);
    stones.force_opacity(forced_opacity::opaque);
    stones.accept_any_intersection(any);
    auto found = stones.intersect(r, g.scene, 0xFF);
    if (found.type == intersection_type::triangle) {
        hit.t = found.distance;
        hit.barycentrics = found.triangle_barycentric_coord;
        hit.what = int(found.instance_id);
        hit.triangle = g.stones[found.instance_id].first + found.primitive_id;
    }
    return hit;
#endif
    for (int k = 0; k < 3; k++) {
        constant TraceStone &stone = g.stones[k];
        if (!mightMeet(origin, direction, hit.t, stone)) {
            continue;
        }
        float3 o = (stone.toObject * float4(origin, 1)).xyz;
        float3 d = (stone.toObject * float4(direction, 0)).xyz;
        float limit = hit.t;
        Hit found;
        if (traceStone(o, d, limit, g, stone, any, found)) {
            hit.t = found.t;
            hit.barycentrics = found.barycentrics;
            hit.triangle = found.triangle;
            hit.what = k;
            if (any) {
                return hit;
            }
        }
    }
    return hit;
}

/// Whether anything stands between `origin` and the sky toward `direction`: a stone, or the ground.
static inline bool blocked(float3 origin, float3 direction, thread const Geometry &g) {
    if (direction.y <= 0) {
        return true;
    }
    return trace(origin, direction, INFINITY, g, true).what >= 0;
}

// MARK: Light

/// The sky's radiance toward `direction`, above the horizon: its tint, deeper higher up, as far up as
/// the view reaches; above that, out of sight, brightening toward the zenith as a pale sky full of
/// light does (an overcast sky is about three times as bright overhead as at the horizon); and brighter
/// around the key light, as the sky is around the sun.
static float3 sky(float3 direction, constant TraceUniforms &u) {
    float elevation = asin(clamp(direction.y, -1.0, 1.0));
    float3 color = mix(u.skyHorizon.rgb, u.skyTop.rgb, smoothstep(0.0, 0.55, max(elevation, 0.0)));
    color *= 1 + (u.zenith - 1) * smoothstep(u.zenithFrom, u.zenithTo, elevation);
    float angle = acos(clamp(dot(direction, u.glowCenter.xyz), -1.0, 1.0));
    return color + u.glow.rgb * exp(-angle * angle / (u.glow.w * u.glow.w));
}

/// The sky as the camera sees it. By night, against the dark sky, the glow around a low sun or moon off
/// to one side would show high in the view like haze; the view keeps the sky's own tint, as a backdrop
/// does, while the glow still lights the stones and the ground.
static float3 skySeen(float3 direction, constant TraceUniforms &u) {
    if (u.isDark < 0.5) {
        return sky(direction, u);
    }
    float elevation = asin(clamp(direction.y, -1.0, 1.0));
    float3 color = mix(u.skyHorizon.rgb, u.skyTop.rgb, smoothstep(0.0, 0.55, max(elevation, 0.0)));
    return color * (1 + (u.zenith - 1) * smoothstep(u.zenithFrom, u.zenithTo, elevation));
}

static inline float conePdf(constant TraceUniforms &u) {
    return 1 / (2 * M_PI_F * (1 - u.key.w));
}

/// How thick the fog is at `p`: none in the clearing around the stones, thickening into a bank around
/// it, thinning with height.
static inline float fogDensity(float3 p, constant TraceUniforms &u) {
    float r = length(p.xz - u.stack.xz);
    return u.fog.z * smoothstep(u.fog.x, u.fog.y, r) * exp(-max(p.y, 0.0) / u.fog.w);
}

/// What the fog does to light coming `distance` along a ray toward the eye: how much of it gets through,
/// and the light it scatters in on the way. Sampled at points spaced out further and further, as the
/// fog lies further out, starting at a random place so the samples average out.
static float3 throughFog(float3 origin, float3 direction, float distance, constant TraceUniforms &u,
                         float offset, thread float &transmittance) {
    transmittance = 1;
    float end = min(distance, 4000.0);
    if (u.fog.z <= 0 || end <= 0) {
        return 0;
    }
    const int steps = 14;
    float start = min(0.3, end);
    // Light scattered toward the eye: the key light's, mostly forward (Henyey-Greenstein), and the
    // light from all around.
    const float g = 0.25;
    float c = dot(direction, u.key.xyz);
    float phase = (1 - g * g) / (4 * M_PI_F * pow(1 + g * g - 2 * g * c, 1.5));
    float3 source = u.fogAlbedo.rgb * (u.fogLight.rgb + phase * u.keyRadiance.rgb * (2 * M_PI_F * (1 - u.key.w)));
    float3 light = 0;
    float previous = 0;
    for (int i = 0; i < steps; i++) {
        float next = start * pow(end / start, float(i + 1) / steps);
        float sigma = fogDensity(origin + direction * mix(previous, next, offset), u);
        float through = exp(-sigma * (next - previous));
        light += transmittance * (1 - through) * source;
        transmittance *= through;
        previous = next;
    }
    return light;
}

// MARK: Surfaces

/// Everything about a surface that decides how it reflects light.
struct Surface {
    float3 position;
    float3 normal;
    /// The surface's true facing, and where rays leaving it start: just off it, and on a stone, off the
    /// smooth surface its triangles stand in for, or a ray toward light grazing it would catch on the
    /// neighboring triangles and leave dark specks (Hanika 2021).
    float3 facing;
    float3 start;
    float3 albedo;
    float roughness;
    float f0;
};

static inline float ggx(float nh, float a2) {
    float d = nh * nh * (a2 - 1) + 1;
    return a2 / (M_PI_F * d * d);
}

/// Smith's visibility for GGX, height correlated, with the 1 / (4 n.l n.v) folded in.
static inline float visibility(float nv, float nl, float a2) {
    float v = nl * sqrt(nv * nv * (1 - a2) + a2), l = nv * sqrt(nl * nl * (1 - a2) + a2);
    return 0.5 / max(v + l, 1e-7);
}

static inline float schlick(float f0, float c) {
    float m = 1 - saturate(c);
    float m2 = m * m;
    return f0 + (1 - f0) * m2 * m2 * m;
}

/// The light reflected toward `out` for light arriving from `in`, per unit of that light, times the
/// cosine at the surface: matte reflection under a glossy one.
static float3 reflectance(thread const Surface &s, float3 in, float3 out) {
    float nl = dot(s.normal, in), nv = dot(s.normal, out);
    if (nl <= 0 || nv <= 0) {
        return 0;
    }
    float3 h = normalize(in + out);
    float vh = saturate(dot(out, h));
    float a = s.roughness * s.roughness, a2 = max(a * a, 1e-6);
    float f = schlick(s.f0, vh);
    float3 base = s.albedo / M_PI_F * (1 - f) + ggx(saturate(dot(s.normal, h)), a2) * visibility(nv, nl, a2) * f;
    return base * nl;
}

/// A direction a microfacet surface around `n`, `alpha` rough, reflects light from `out` into, as
/// likely as the visible facets make it (Heitz 2018).
static float3 glossySample(float3 n, float3 out, float alpha, float2 xi) {
    float3 t, b;
    basis(n, t, b);
    float3 v = float3(dot(out, t), dot(out, b), dot(out, n));
    float3 vh = normalize(float3(alpha * v.x, alpha * v.y, v.z));
    float lengthSquared = vh.x * vh.x + vh.y * vh.y;
    float3 t1 = lengthSquared > 0 ? float3(-vh.y, vh.x, 0) * rsqrt(lengthSquared) : float3(1, 0, 0);
    float3 t2 = cross(vh, t1);
    float r = sqrt(xi.x), phi = 2 * M_PI_F * xi.y;
    float p1 = r * cos(phi), p2 = r * sin(phi);
    float s = 0.5 * (1 + vh.z);
    p2 = (1 - s) * sqrt(max(0.0, 1 - p1 * p1)) + s * p2;
    float3 nh = p1 * t1 + p2 * t2 + sqrt(max(0.0, 1 - p1 * p1 - p2 * p2)) * vh;
    float3 hl = normalize(float3(alpha * nh.x, alpha * nh.y, max(nh.z, 1e-6)));
    float3 h = t * hl.x + b * hl.y + n * hl.z;
    return reflect(-out, h);
}

static inline float glossyPdf(float3 n, float3 out, float3 in, float alpha) {
    float nv = dot(n, out), nl = dot(n, in);
    if (nv <= 0 || nl <= 0) {
        return 0;
    }
    float3 h = normalize(in + out);
    float a2 = max(alpha * alpha, 1e-6);
    float g1 = 2 * nv / (nv + sqrt(a2 + (1 - a2) * nv * nv));
    return ggx(saturate(dot(n, h)), a2) * g1 / (4 * nv);
}

/// How likely bouncing on off the glossy layer is, rather than matte.
static inline float glossShare(thread const Surface &s) {
    return mix(0.15, 0.5, smoothstep(0.6, 0.1, s.roughness));
}

static float bouncePdf(thread const Surface &s, float3 out, float3 in) {
    float gloss = glossShare(s);
    return (1 - gloss) * max(dot(s.normal, in), 0.0) / M_PI_F
        + gloss * glossyPdf(s.normal, out, in, s.roughness * s.roughness);
}

static float3 bounceSample(thread const Surface &s, float3 out, thread uint &random) {
    float pick = next(random);
    float2 xi = next2(random);
    if (pick < glossShare(s)) {
        return glossySample(s.normal, out, s.roughness * s.roughness, xi);
    }
    return cosineSample(s.normal, xi);
}

// MARK: Stones

/// The stone's surface where a ray meets it: the grain and finish of its material.
static Surface stoneSurface(Hit hit, float3 origin, float3 direction, thread const Geometry &g,
                            constant TraceUniforms &u, texture2d<float> color, texture2d<float> relief) {
    constexpr sampler tiled(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    constant TraceStone &stone = g.stones[hit.what];
    uint i0 = g.indices[hit.triangle * 3], i1 = g.indices[hit.triangle * 3 + 1], i2 = g.indices[hit.triangle * 3 + 2];
    float3 w = float3(1 - hit.barycentrics.x - hit.barycentrics.y, hit.barycentrics.x, hit.barycentrics.y);
    float3x3 rotation = float3x3(stone.toWorld[0].xyz, stone.toWorld[1].xyz, stone.toWorld[2].xyz);
    float3 normal = normalize(rotation * (g.normals[i0].xyz * w.x + g.normals[i1].xyz * w.y + g.normals[i2].xyz * w.z));
    float3 across = rotation * (g.tangents[i0].xyz * w.x + g.tangents[i1].xyz * w.y + g.tangents[i2].xyz * w.z);
    float3 along = rotation * (g.bitangents[i0].xyz * w.x + g.bitangents[i1].xyz * w.y + g.bitangents[i2].xyz * w.z);
    float2 uv = g.coordinates[i0] * w.x + g.coordinates[i1] * w.y + g.coordinates[i2] * w.z;

    Surface s;
    s.position = origin + direction * hit.t;
    // The triangle's own facing, toward where the ray came from, for starting rays off it.
    float3 p0 = g.positions[i0].xyz, p1 = g.positions[i1].xyz, p2 = g.positions[i2].xyz;
    float3 flat = normalize(rotation * cross(p1 - p0, p2 - p0));
    s.facing = dot(flat, direction) < 0 ? flat : -flat;
    float3 local = p0 * w.x + p1 * w.y + p2 * w.z;
    float3 n0 = normalize(g.normals[i0].xyz), n1 = normalize(g.normals[i1].xyz), n2 = normalize(g.normals[i2].xyz);
    float3 a = local - p0, b = local - p1, c = local - p2;
    a -= min(0.0, dot(a, n0)) * n0;
    b -= min(0.0, dot(b, n1)) * n1;
    c -= min(0.0, dot(c, n2)) * n2;
    float3 lifted = rotation * (w.x * a + w.y * b + w.z * c);
    s.start = s.position + (dot(lifted, s.facing) > 0 ? lifted : 0) + s.facing * 3e-5;
    if (length_squared(across) < 1e-12 || length_squared(along) < 1e-12) {
        basis(normal, across, along);
    }
    float3 grain = color.sample(tiled, uv, level(0)).rgb;
    float3 tilt = relief.sample(tiled, uv, level(0)).rgb;
    // Fine grain: the relief only just tilts the surface.
    float2 slope = (tilt.rg - 0.5) * u.reliefDepth;
    s.albedo = grain * u.stoneAlbedo.rgb;
    s.roughness = u.roughness * (0.4 + 1.2 * tilt.b);
    s.f0 = 0.08 * u.specular;
    s.normal = normalize(normal - normalize(across) * slope.x + normalize(along) * slope.y);
    // Seen from behind, a shading normal would let light through; keep it facing the eye.
    if (dot(s.normal, -direction) < 0.02) {
        s.normal = normalize(s.normal - direction * (0.02 - dot(s.normal, -direction)));
    }
    return s;
}

// MARK: Ground

/// The ground where a ray meets it: matte.
static Surface groundSurface(float3 position, constant TraceUniforms &u) {
    Surface s;
    s.position = position;
    s.normal = float3(0, 1, 0);
    s.facing = s.normal;
    s.start = position + float3(0, 2e-4, 0);
    s.albedo = u.groundAlbedo.rgb;
    s.roughness = 0.85;
    s.f0 = 0.04;
    return s;
}

// MARK: The ground's light

/// The light falling on the ground is kept in a map lying on it, finest near the stones and ever coarser
/// further off, out to the horizon: each coordinate from -1 to 1 is d / (k + |d|) of the distance d from
/// the stack, in meters.
constant float groundMapReach = 0.5;

static inline float2 toGroundMap(float2 xz, constant TraceUniforms &u) {
    float2 d = xz - u.stack.xz;
    return d / (groundMapReach + abs(d));
}

static inline float2 fromGroundMap(float2 m, constant TraceUniforms &u) {
    return u.stack.xz + groundMapReach * m / max(1 - abs(m), 1e-4);
}

/// The light falling on the ground at `p` as last worked out: the open sky's and the key light's, less
/// what the stones keep off, plus what they throw onto it.
static inline float3 groundLight(float3 p, constant TraceUniforms &u, texture2d<float> map) {
    constexpr sampler smooth(coord::normalized, filter::linear, address::clamp_to_edge);
    // Where hardly any light gets in, the average of its samples (some below nothing) can still dip
    // below nothing.
    return max(map.sample(smooth, toGroundMap(p.xz, u) * 0.5 + 0.5).rgb, 0.0);
}

// MARK: Gathering light

/// One sample of the light leaving a surface toward `out`, along a path that bounces on up to `depth`
/// more times between the stones and the ground, as light really goes on bouncing between pale
/// surfaces. At each surface it meets it picks up light straight from the key light and the sky. On a
/// stone, that's weighed against bouncing into them by chance (multiple importance), and the path bounces
/// on as the stone reflects light. On the ground, the light a level patch gets in the open is known
/// exactly; what the stones take away from it is found by chance, and where a stone stands in the way of
/// the sky, the path goes on to that stone instead, so the ground gets its light. Where nothing is
/// `near` enough to matter, the ground's light is just the open light.
static float3 pathLight(Surface s, float3 out, thread const Geometry &g, constant TraceUniforms &u,
                        thread uint &random, texture2d<float> color, texture2d<float> relief, uint depth,
                        texture2d<float> map) {
    float3 light = 0, carried = 1;
    for (uint bounce = 0; bounce <= depth; bounce++) {
        float3 start = s.start;
        bool last = bounce == depth;
        // A stone: straight from the key light and the sky, weighed against finding them by bouncing.
        float3 toKey = coneSample(u.key.xyz, u.key.w, next2(random));
        float3 f = reflectance(s, toKey, out);
        if (any(f > 0) && !blocked(start, toKey, g)) {
            float lightPdf = conePdf(u), bounced = bouncePdf(s, out, toKey);
            light += carried * f * u.keyRadiance.rgb / lightPdf * (lightPdf * lightPdf / (lightPdf * lightPdf + bounced * bounced));
        }
        float3 toSky = cosineSample(s.normal, next2(random));
        if (toSky.y > 0) {
            float lightPdf = max(dot(s.normal, toSky), 1e-4) / M_PI_F, bounced = bouncePdf(s, out, toSky);
            float3 fs = reflectance(s, toSky, out);
            if (any(fs > 0) && !blocked(start, toSky, g)) {
                light += carried * fs * sky(toSky, u) / lightPdf * (lightPdf * lightPdf / (lightPdf * lightPdf + bounced * bounced));
            }
        }
        if (last) {
            break;
        }
        // On, the way the stone reflects light.
        float3 onward = bounceSample(s, out, random);
        float pdf = bouncePdf(s, out, onward);
        float3 weight = pdf > 0 ? reflectance(s, onward, out) / pdf : float3(0);
        if (!any(weight > 0)) {
            break;
        }
        carried *= weight;
        // Paths that carry little light end early, the rest carry the difference.
        if (bounce >= 1) {
            float keep = clamp(max(carried.r, max(carried.g, carried.b)), 0.1, 0.95);
            if (next(random) > keep) {
                break;
            }
            carried /= keep;
        }
        Hit hit = trace(start, onward, INFINITY, g, false);
        if (hit.what < 0) {
            // Out to the sky (only above the horizon; below it there's the ground).
            float skyPdf = max(dot(s.normal, onward), 0.0) / M_PI_F;
            float3 seen = sky(onward, u) * (pdf * pdf / (pdf * pdf + skyPdf * skyPdf));
            if (dot(onward, u.key.xyz) > u.key.w) {
                float lightPdf = conePdf(u);
                seen += u.keyRadiance.rgb * (pdf * pdf / (pdf * pdf + lightPdf * lightPdf));
            }
            light += carried * seen;
            break;
        }
        out = -onward;
        if (hit.what == 3) {
            // The ground: as much light as falls on it there, as worked out on the ground's own map.
            Surface ground = groundSurface(start + onward * hit.t, u);
            light += carried * ground.albedo / M_PI_F * groundLight(ground.position, u, map);
            break;
        }
        s = stoneSurface(hit, start, onward, g, u, color, relief);
    }
    return light;
}

/// The light leaving the ground at `s`: what falls on it, from its map, reflected by its matte surface.
static float3 groundShade(thread const Surface &s, constant TraceUniforms &u, texture2d<float> map) {
    return s.albedo / M_PI_F * groundLight(s.position, u, map);
}

/// Works out the light falling on the ground near and far, one sample a texel each frame, averaged with
/// the samples before as the screen's are: the open sky's and the key light's, less what the stones keep
/// off, plus the light they throw onto it, found by following light back off them (and off the ground
/// again, as last worked out here, so it bounces on and on).
kernel void groundMapKernel(uint2 texel [[thread_position_in_grid]],
                            constant TraceUniforms &u [[buffer(0)]],
                            constant TraceStone *stones [[buffer(1)]],
                            device const TraceNode *nodes [[buffer(3)]],
                            device const float4 *triangles [[buffer(4)]],
                            device const uint *indices [[buffer(5)]],
                            device const float4 *normals [[buffer(6)]],
                            device const float4 *tangents [[buffer(7)]],
                            device const float4 *bitangents [[buffer(8)]],
                            device const float2 *coordinates [[buffer(9)]],
                            device const float4 *positions [[buffer(15)]],
#if !SOFTWARE_RAYS
                            instance_acceleration_structure scene [[buffer(16)]],
#endif
                            texture2d<float> color [[texture(0)]],
                            texture2d<float> relief [[texture(1)]],
                            texture2d<float> before [[texture(2)]],
                            texture2d<float, access::write> after [[texture(3)]]) {
    uint size = before.get_width();
    if (texel.x >= size || texel.y >= size) {
        return;
    }
#if SOFTWARE_RAYS
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions };
#else
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions, scene };
#endif
    uint random = hashed(texel.x * 7919u + texel.y * 104729u + u.frame * 15485863u) | 1u;
    float2 m = ((float2(texel) + 0.5) / float(size)) * 2 - 1;
    float2 xz = fromGroundMap(m, u);
    float3 at = float3(xz.x, 0, xz.y);
    float3 start = at + float3(0, 2e-4, 0);
    float3 light = u.skyIrradiance.rgb + u.keyIrradiance.rgb;
    float3 toKey = coneSample(u.key.xyz, u.key.w, next2(random));
    if (toKey.y > 0 && blocked(start, toKey, g)) {
        light -= u.keyRadiance.rgb / conePdf(u) * toKey.y;
    }
    float3 toSky = cosineSample(float3(0, 1, 0), next2(random));
    Hit hit = trace(start, toSky, INFINITY, g, false);
    if (hit.what >= 0 && hit.what < 3) {
        Surface stone = stoneSurface(hit, start, toSky, g, u, color, relief);
        light += M_PI_F * (pathLight(stone, -toSky, g, u, random, color, relief, max(u.bounces, 1u) - 1, before) - sky(toSky, u));
    }
    if (!all(isfinite(light))) {
        light = u.skyIrradiance.rgb + u.keyIrradiance.rgb;
    }
    float4 last = before.read(texel);
    float n = u.limit > 0 ? min(last.a, float(u.limit)) : 0;
    after.write(float4(last.rgb + (light - last.rgb) / (n + 1), min(n + 1, 4000.0)), texel);
}

// MARK: Kernels

static inline float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

/// Adds this frame's samples to each pixel's average, carrying the average along with what the pixel
/// shows: where a stone has moved since last frame, from where that bit of it was then. Also notes, for
/// the denoiser, which way the surface faces, its color, and whether its light comes from random
/// samples at all (open sky and open ground don't: one sample is exact).
kernel void traceKernel(uint2 grid [[thread_position_in_grid]],
                        constant TraceUniforms &u [[buffer(0)]],
                        constant TraceStone *stones [[buffer(1)]],
                        constant TraceStone *before [[buffer(2)]],
                        device const TraceNode *nodes [[buffer(3)]],
                        device const float4 *triangles [[buffer(4)]],
                        device const uint *indices [[buffer(5)]],
                        device const float4 *normals [[buffer(6)]],
                        device const float4 *tangents [[buffer(7)]],
                        device const float4 *bitangents [[buffer(8)]],
                        device const float2 *coordinates [[buffer(9)]],
                        device const half4 *history [[buffer(10)]],
                        device const half4 *historyDetails [[buffer(11)]],
                        device half4 *accumulated [[buffer(12)]],
                        device half4 *details [[buffer(13)]],
                        device half4 *guides [[buffer(14)]],
                        device const float4 *positions [[buffer(15)]],
#if !SOFTWARE_RAYS
                        instance_acceleration_structure scene [[buffer(16)]],
#endif
                        texture2d<float> color [[texture(0)]],
                        texture2d<float> relief [[texture(1)]],
                        texture2d<float> map [[texture(2)]]) {
    uint width = uint(u.viewSize.x), height = uint(u.viewSize.y), columns = u.regionWidth;
    uint2 pixel = grid + uint2(u.regionLeft, u.regionTop);
    if (grid.x >= columns || grid.y >= u.regionHeight || pixel.x >= width || pixel.y >= height) {
        return;
    }
#if SOFTWARE_RAYS
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions };
#else
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions, scene };
#endif
    uint random = hashed(pixel.x * 1973u + pixel.y * 9277u + u.frame * 26699u) | 1u;
    float2 p = (float2(pixel) + 0.5 + u.jitter) / u.pixelsPerPoint;
    float3 direction = normalize(u.forward.xyz + (p.x - u.center.x) / u.focal * u.right.xyz
                                 + (u.center.y - p.y) / u.focal * u.up.xyz);
    float3 out = -direction;
    Hit hit = trace(u.eye.xyz, direction, INFINITY, g, false);
    float through;
    float3 fogged = throughFog(u.eye.xyz, direction, hit.what < 0 ? INFINITY : hit.t, u, 0.5, through);

    float3 light = 0, albedo = 1, facing = float3(0, 1, 0);
    float second = 0;
    bool noisy = false;
    if (hit.what < 0) {
        light = skySeen(direction, u) * through + fogged;
        second = luminance(light) * luminance(light);
    } else if (hit.what == 3) {
        Surface ground = groundSurface(u.eye.xyz + direction * hit.t, u);
        albedo = ground.albedo;
        // Its light comes from the ground's map, so one sample is exact.
        light = groundShade(ground, u, map) * through + fogged;
        second = luminance(light) * luminance(light);
    } else {
        Surface s = stoneSurface(hit, u.eye.xyz, direction, g, u, color, relief);
        albedo = s.albedo;
        facing = s.normal;
        noisy = true;
        for (uint k = 0; k < u.samples; k++) {
            float3 one = pathLight(s, out, g, u, random, color, relief, u.bounces, map) * through + fogged;
            light += one;
            second += luminance(one) * luminance(one);
        }
        light /= u.samples;
        second /= u.samples;
    }
    // A stray sample far brighter than the rest would show as a speck for a long while.
    float peak = max(light.r, max(light.g, light.b));
    if (peak > 64) {
        light *= 64 / peak;
        second *= (64 / peak) * (64 / peak);
    }
    if (!all(isfinite(light))) {
        light = 0;
        second = 0;
    }
    float depth = hit.what < 0 ? 60000.0 : hit.t * dot(direction, u.forward.xyz);

    // Where this pixel's average was last frame: the same pixel, unless it shows a stone that has moved.
    float2 then = float2(pixel) + 0.5;
    float expected = depth;
    if (hit.what >= 0 && hit.what < 3) {
        float3 world = u.eye.xyz + direction * hit.t;
        float3 local = (stones[hit.what].toObject * float4(world, 1)).xyz;
        float3 was = (before[hit.what].toWorld * float4(local, 1)).xyz;
        float3 away = was - u.eye.xyz;
        expected = dot(away, u.forward.xyz);
        float2 points = u.center + u.focal * float2(dot(away, u.right.xyz), -dot(away, u.up.xyz)) / max(expected, 1e-3);
        then = points * u.pixelsPerPoint;
    }
    int2 at = int2(floor(then)) - int2(u.regionLeft, u.regionTop);
    float n = 0;
    float3 average = 0;
    float averageSecond = 0;
    bool wasNoisy = false;
    if (u.limit > 0 && at.x >= 0 && at.y >= 0 && at.x < int(columns) && at.y < int(u.regionHeight)) {
        uint j = uint(at.y) * columns + uint(at.x);
        half4 last = history[j];
        half4 lastDetails = historyDetails[j];
        // While things move, only take what it showed if it's the same thing, about as far off.
        bool same = u.limit > 65535 || (int(lastDetails.y) % 8 == hit.what + (hit.what < 0 ? 8 : 0)
            && (hit.what < 0 || abs(float(lastDetails.x) - expected) < 0.03 * expected + 0.003));
        if (same) {
            n = min(float(last.a), float(u.limit));
            average = float3(last.rgb);
            averageSecond = float(lastDetails.w);
            wasNoisy = int(lastDetails.y) >= 8;
        }
    }
    // Pixels whose light needs no random samples are exact at once; but a pixel that has also shown
    // something noisy, as along a stone's edge, averages everything it has shown.
    noisy = noisy || wasNoisy;
    float weight = noisy ? 1 / (n + 1) : 1;

    uint i = grid.y * columns + grid.x;
    accumulated[i] = half4(half3(average + (light - average) * weight), half(min(n + 1, 2000.0)));
    details[i] = half4(half(min(depth, 60000.0)), half((hit.what < 0 ? hit.what + 8 : hit.what) + (noisy ? 8 : 0)), 0,
                       half(averageSecond + (second - averageSecond) * weight));
    guides[i] = half4(half3(facing), half(luminance(albedo)));

}

/// What the mist does along each pixel's line of sight, worked out again only when the light changes:
/// for the sky, all the light that reaches the eye (alpha below 0); for the ground, the light the mist
/// scatters in (rgb) and how much of the ground's own light gets through (alpha).
kernel void mistKernel(uint2 pixel [[thread_position_in_grid]],
                       constant TraceUniforms &u [[buffer(0)]],
                       texture2d<float, access::write> mist [[texture(0)]]) {
    if (pixel.x >= uint(u.viewSize.x) || pixel.y >= uint(u.viewSize.y)) {
        return;
    }
    float2 p = (float2(pixel) + 0.5) / u.pixelsPerPoint;
    float3 direction = normalize(u.forward.xyz + (p.x - u.center.x) / u.focal * u.right.xyz
                                 + (u.center.y - p.y) / u.focal * u.up.xyz);
    float t = direction.y < -1e-7 ? -u.eye.y / direction.y : INFINITY;
    float through;
    float3 fogged = throughFog(u.eye.xyz, direction, t, u, 0.5, through);
    mist.write(isinf(t) ? float4(skySeen(direction, u) * through + fogged, -1) : float4(fogged, through), pixel);
}

/// The scene away from the stones: the sky, and the ground lit as its map says, seen through the mist.
kernel void backdropKernel(uint2 pixel [[thread_position_in_grid]],
                           constant TraceUniforms &u [[buffer(0)]],
                           texture2d<float, access::write> backdrop [[texture(0)]],
                           texture2d<float> map [[texture(1)]],
                           texture2d<float> mist [[texture(2)]]) {
    if (pixel.x >= uint(u.viewSize.x) || pixel.y >= uint(u.viewSize.y)) {
        return;
    }
    float4 seen = mist.read(pixel);
    if (seen.a < 0) {
        backdrop.write(float4(seen.rgb, 1), pixel);
        return;
    }
    float2 p = (float2(pixel) + 0.5) / u.pixelsPerPoint;
    float3 direction = normalize(u.forward.xyz + (p.x - u.center.x) / u.focal * u.right.xyz
                                 + (u.center.y - p.y) / u.focal * u.up.xyz);
    float t = -u.eye.y / min(direction.y, -1e-7);
    Surface ground = groundSurface(u.eye.xyz + direction * t, u);
    float3 light = groundShade(ground, u, map) * seen.a + seen.rgb;
    backdrop.write(float4(light, 1), pixel);
}

/// How much of the light around a glossy surface it reflects, all told, seen from `nv` with `roughness`,
/// over a mirror's share face on (a fit to the integral, after Karis): for MetalFX to tell its shine from
/// its color.
static inline float2 reflectedShare(float nv, float roughness) {
    const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

/// One sample of each pixel's light, for MetalFX to denoise and scale up (where the GPU can): traced at
/// a lower resolution than the screen, with what the denoiser needs to know about each pixel: how far
/// off it is (as reversed depth), where it was last frame, its surface's color, how glossy it is and
/// which way it faces.
kernel void traceFXKernel(uint2 pixel [[thread_position_in_grid]],
                          constant TraceUniforms &u [[buffer(0)]],
                          constant TraceStone *stones [[buffer(1)]],
                          constant TraceStone *before [[buffer(2)]],
                          device const TraceNode *nodes [[buffer(3)]],
                          device const float4 *triangles [[buffer(4)]],
                          device const uint *indices [[buffer(5)]],
                          device const float4 *normals [[buffer(6)]],
                          device const float4 *tangents [[buffer(7)]],
                          device const float4 *bitangents [[buffer(8)]],
                          device const float2 *coordinates [[buffer(9)]],
                          device const float4 *positions [[buffer(15)]],
#if !SOFTWARE_RAYS
                          instance_acceleration_structure scene [[buffer(16)]],
#endif
                          texture2d<float> color [[texture(0)]],
                          texture2d<float> relief [[texture(1)]],
                          texture2d<float, access::write> radianceOut [[texture(2)]],
                          texture2d<float, access::write> depthOut [[texture(3)]],
                          texture2d<float, access::write> motionOut [[texture(4)]],
                          texture2d<float, access::write> albedoOut [[texture(5)]],
                          texture2d<float, access::write> specularOut [[texture(6)]],
                          texture2d<float, access::write> normalOut [[texture(7)]],
                          texture2d<float, access::write> roughnessOut [[texture(8)]],
                          texture2d<float> map [[texture(9)]]) {
    uint width = uint(u.viewSize.x), height = uint(u.viewSize.y);
    if (pixel.x >= width || pixel.y >= height) {
        return;
    }
#if SOFTWARE_RAYS
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions };
#else
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions, scene };
#endif
    uint random = hashed(pixel.x * 1973u + pixel.y * 9277u + u.frame * 26699u) | 1u;
    float2 p = (float2(pixel) + 0.5 + u.jitter) / u.pixelsPerPoint;
    float3 direction = normalize(u.forward.xyz + (p.x - u.center.x) / u.focal * u.right.xyz
                                 + (u.center.y - p.y) / u.focal * u.up.xyz);
    float3 out = -direction;
    Hit hit = trace(u.eye.xyz, direction, INFINITY, g, false);
    float through;
    float3 fogged = throughFog(u.eye.xyz, direction, hit.what < 0 ? INFINITY : hit.t, u, 0.5, through);

    float3 light = 0, albedo = 1, facing = out, specular = 0;
    float roughness = 1;
    if (hit.what < 0) {
        light = skySeen(direction, u) * through + fogged;
    } else if (hit.what == 3) {
        Surface ground = groundSurface(u.eye.xyz + direction * hit.t, u);
        albedo = ground.albedo;
        facing = ground.normal;
        roughness = ground.roughness;
        light = groundShade(ground, u, map) * through + fogged;
    } else {
        Surface s = stoneSurface(hit, u.eye.xyz, direction, g, u, color, relief);
        albedo = s.albedo;
        facing = s.normal;
        roughness = s.roughness;
        float2 share = reflectedShare(saturate(dot(s.normal, out)), s.roughness);
        specular = s.f0 * share.x + share.y;
        albedo *= 1 - specular;
        for (uint k = 0; k < u.samples; k++) {
            light += pathLight(s, out, g, u, random, color, relief, u.bounces, map);
        }
        light = light / u.samples * through + fogged;
    }
    float peak = max(light.r, max(light.g, light.b));
    if (peak > 64) {
        light *= 64 / peak;
    }
    if (!all(isfinite(light))) {
        light = 0;
    }
    float viewDepth = hit.what < 0 ? INFINITY : hit.t * dot(direction, u.forward.xyz);

    // Where this bit of the scene was last frame: the same place, unless it's on a stone that moved.
    float2 then = float2(pixel) + 0.5;
    if (hit.what >= 0 && hit.what < 3) {
        float3 world = u.eye.xyz + direction * hit.t;
        float3 local = (stones[hit.what].toObject * float4(world, 1)).xyz;
        float3 was = (before[hit.what].toWorld * float4(local, 1)).xyz;
        float3 away = was - u.eye.xyz;
        float ahead = dot(away, u.forward.xyz);
        then = (u.center + u.focal * float2(dot(away, u.right.xyz), -dot(away, u.up.xyz)) / max(ahead, 1e-3)) * u.pixelsPerPoint;
    }
    radianceOut.write(float4(light, 1), pixel);
    depthOut.write(float4(hit.what < 0 ? 0.0 : 0.05 / viewDepth), pixel);
    motionOut.write(float4(then - (float2(pixel) + 0.5), 0, 0), pixel);
    albedoOut.write(float4(saturate(albedo), 1), pixel);
    specularOut.write(float4(float3(saturate(specular)), 1), pixel);
    normalOut.write(float4(facing, 0), pixel);
    roughnessOut.write(float4(roughness), pixel);
}

/// Ready for denoising: each noisy pixel's light, divided by its surface's color so the filter blurs only
/// the light, not the stone's grain; and how uncertain that is. Pixels with few samples behind them don't
/// know their own spread yet, so take their neighbors'.
kernel void varianceKernel(uint2 grid [[thread_position_in_grid]],
                           constant TraceUniforms &u [[buffer(0)]],
                           device const half4 *accumulated [[buffer(1)]],
                           device const half4 *details [[buffer(2)]],
                           device const half4 *guides [[buffer(3)]],
                           device half4 *filtered [[buffer(4)]]) {
    uint columns = u.regionWidth;
    if (grid.x >= columns || grid.y >= u.regionHeight) {
        return;
    }
    uint i = grid.y * columns + grid.x;
    half4 d = details[i];
    int code = int(d.y);
    if (code < 8) {
        filtered[i] = half4(0, 0, 0, -1);
        return;
    }
    int what = code - 8;
    float3 c = float3(accumulated[i].rgb);
    float n = float(accumulated[i].a);
    float a = max(float(guides[i].w), 0.03);
    float l = luminance(c);
    float variance;
    if (n >= 4) {
        variance = max(float(d.w) - l * l, 0.0) / n;
    } else {
        // From the neighbors showing the same thing.
        float sum = 0, sumSquares = 0, count = 0;
        for (int y = -3; y <= 3; y++) {
            for (int x = -3; x <= 3; x++) {
                int2 q = int2(grid) + int2(x, y);
                if (q.x < 0 || q.y < 0 || q.x >= int(columns) || q.y >= int(u.regionHeight)) {
                    continue;
                }
                uint k = uint(q.y) * columns + uint(q.x);
                if (int(details[k].y) - 8 != what) {
                    continue;
                }
                float lq = luminance(float3(accumulated[k].rgb));
                sum += lq;
                sumSquares += lq * lq;
                count += 1;
            }
        }
        float mean = sum / max(count, 1.0);
        variance = max(sumSquares / max(count, 1.0) - mean * mean, 0.0) * 4 / max(n, 1.0);
    }
    filtered[i] = half4(half3(c / a), half(variance / (a * a)));
}

/// One pass of the denoiser (edge-avoiding à-trous wavelets, Dammertz et al.; as in SVGF, Schied et al.):
/// each noisy pixel's light averaged with its neighbors `step` pixels apart, as far as they show the same
/// surface, facing the same way, about as far off, and lit about the same, given how uncertain each is.
kernel void atrousKernel(uint2 grid [[thread_position_in_grid]],
                         constant TraceUniforms &u [[buffer(0)]],
                         constant int &step [[buffer(1)]],
                         device const half4 *input [[buffer(2)]],
                         device const half4 *details [[buffer(3)]],
                         device const half4 *guides [[buffer(4)]],
                         device half4 *output [[buffer(5)]]) {
    uint columns = u.regionWidth;
    if (grid.x >= columns || grid.y >= u.regionHeight) {
        return;
    }
    uint i = grid.y * columns + grid.x;
    half4 middle = input[i];
    if (middle.a < 0 || float(middle.a) < 1e-7) {
        output[i] = middle;
        return;
    }
    int what = int(details[i].y);
    float depth = float(details[i].x);
    float3 normal = float3(guides[i].xyz);
    float l = luminance(float3(middle.rgb));
    float spread = 4 * sqrt(max(float(middle.a), 0.0)) + 1e-4;
    const float taps[3] = {3.0 / 8, 1.0 / 4, 1.0 / 16};
    float3 sum = 0;
    float total = 0, variance = 0;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            int2 q = int2(grid) + int2(x, y) * step;
            if (q.x < 0 || q.y < 0 || q.x >= int(columns) || q.y >= int(u.regionHeight)) {
                continue;
            }
            uint iq = uint(q.y) * columns + uint(q.x);
            half4 other = input[iq];
            if (other.a < 0 || int(details[iq].y) != what) {
                continue;
            }
            float w = taps[abs(x)] * taps[abs(y)];
            if (x != 0 || y != 0) {
                float3 n = float3(guides[iq].xyz);
                w *= pow(max(dot(normal, n), 0.0), 64.0);
                w *= exp(-abs(float(details[iq].x) - depth) / (0.004 * depth * float(step) + 1e-4));
                w *= exp(-abs(luminance(float3(other.rgb)) - l) / spread);
            }
            sum += w * float3(other.rgb);
            variance += w * w * float(other.a);
            total += w;
        }
    }
    output[i] = half4(half3(sum / total), half(variance / (total * total)));
}

struct DisplayVertex {
    float4 position [[position]];
};

vertex DisplayVertex displayVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    DisplayVertex out;
    out.position = float4(corner * 2 - 1, 0, 1);
    return out;
}

static inline float3 encoded(float3 linear) {
    return select(1.055 * pow(linear, 1.0 / 2.4) - 0.055, 12.92 * linear, linear <= 0.0031308);
}

/// The picture so far, as the screen shows it: around the stones, the samples traced there, fading into
/// the backdrop toward the edges; exposed, with highlights rolling off softly instead of clipping, encoded,
/// with the paper's grain over it; and as it comes in, `fade` of the way over what was shown `before`.
fragment half4 displayFragment(DisplayVertex in [[stage_in]], constant TraceUniforms &u [[buffer(0)]],
                               device const half4 *accumulated [[buffer(1)]],
                               device const half4 *guides [[buffer(3)]],
                               device const half4 *denoised [[buffer(4)]],
                               constant float &fade [[buffer(5)]],
                               texture2d<float> grain [[texture(0)]],
                               texture2d<float> backdrop [[texture(1)]],
                               texture2d<float> before [[texture(2)]]) {
    constexpr sampler tiled(filter::linear, address::repeat);
    uint2 pixel = uint2(in.position.xy);
    float3 light = backdrop.read(pixel).rgb;
    int row = int(pixel.y) - int(u.regionTop), column = int(pixel.x) - int(u.regionLeft);
    if (row >= 0 && row < int(u.regionHeight) && column >= 0 && column < int(u.regionWidth)) {
        uint i = uint(row) * u.regionWidth + uint(column);
        float3 traced = float3(accumulated[i].rgb);
        // While few samples are in, show the denoised light; as more come in, the samples themselves.
        half4 clean = denoised[i];
        if (clean.a >= 0) {
            // Until the samples' own average is within about half a percent, the denoised light is closer.
            float n = float(accumulated[i].a);
            float error = sqrt(max(float(clean.a), 0.0)) / max(luminance(float3(clean.rgb)), 1e-3);
            float3 smooth = float3(clean.rgb) * max(float(guides[i].w), 0.03);
            traced = mix(smooth, traced, smoothstep(0.02, 0.004, error) * smoothstep(8.0, 32.0, n));
        }
        float edge = smoothstep(0.0, 24.0, float(row)) * smoothstep(0.0, 24.0, float(int(u.regionHeight) - 1 - row))
            * smoothstep(0.0, 24.0, float(column)) * smoothstep(0.0, 24.0, float(int(u.regionWidth) - 1 - column));
        light = mix(light, traced, edge);
    }
    light *= u.exposure;
    // The camera's response: straight up to 0.8, then easing off toward white.
    float3 over = max(light - 0.8, 0.0);
    light = min(light, 0.8) + 0.2 * (1 - exp(-over / 0.2));
    float3 base = encoded(saturate(light));
    float g = grain.sample(tiled, in.position.xy / u.pixelsPerPoint / 100).r;
    float3 lit = g <= 0.5 ? base - (1 - 2 * g) * base * (1 - base)
        : base + (2 * g - 1) * (select(sqrt(base), ((16 * base - 12) * base + 4) * base, base <= 0.25) - base);
    float3 shown = mix(base, lit, u.grainOpacity);
    if (fade < 1) {
        shown = mix(before.read(pixel).rgb, shown, fade);
    }
    return half4(half3(shown), 1);
}

/// The denoised picture, as the screen shows it: exposed, with highlights rolling off softly, encoded,
/// with the paper's grain over it.
fragment half4 displayFXFragment(DisplayVertex in [[stage_in]], constant TraceUniforms &u [[buffer(0)]],
                                 texture2d<float> clean [[texture(0)]],
                                 texture2d<float> grain [[texture(1)]],
                                 texture2d<float> backdrop [[texture(2)]]) {
    constexpr sampler tiled(filter::linear, address::repeat);
    uint2 pixel = uint2(in.position.xy);
    float3 light = backdrop.read(pixel).rgb;
    // Around the stones, the denoised picture; it fades into the backdrop toward its edges.
    int row = int(pixel.y) - int(u.regionTop), column = int(pixel.x) - int(u.regionLeft);
    if (row >= 0 && row < int(u.regionHeight) && column >= 0 && column < int(u.regionWidth)) {
        uint2 inside = uint2(uint(column), uint(row));
        float edge = smoothstep(0.0, 24.0, float(row)) * smoothstep(0.0, 24.0, float(int(u.regionHeight) - 1 - row))
            * smoothstep(0.0, 24.0, float(column)) * smoothstep(0.0, 24.0, float(int(u.regionWidth) - 1 - column));
        light = mix(light, clean.read(inside).rgb, edge);
    }
    light *= u.exposure;
    float3 over = max(light - 0.8, 0.0);
    light = min(light, 0.8) + 0.2 * (1 - exp(-over / 0.2));
    float3 base = encoded(saturate(light));
    float n = grain.sample(tiled, in.position.xy / u.pixelsPerPoint / 100).r;
    float3 lit = n <= 0.5 ? base - (1 - 2 * n) * base * (1 - base)
        : base + (2 * n - 1) * (select(sqrt(base), ((16 * base - 12) * base + 4) * base, base <= 0.25) - base);
    return half4(half3(mix(base, lit, u.grainOpacity)), 1);
}

// MARK: Light worked out ahead

// The light that reaches each point of the stones, and of the ground around them, from each direction,
// worked out once for the stones as they rest and kept as spherical harmonics (Sloan, Kautz and Snyder
// 2002, "precomputed radiance transfer"): the same numbers hold however the stack is turned and whatever
// the sky is like, so a frame takes only a sum at each point, with nothing left to chance. It includes
// the light bounced between the stones and the ground. The key light is too small a light for the
// harmonics to hold, so its shadows are traced each frame, the same few directions across it every time.

constant int harmonicOrder = 6;
constant int harmonicCount = harmonicOrder * harmonicOrder;
/// Light that has bounced is soft, and fewer harmonics hold it.
constant int bounceCount = 9;
/// What each point keeps: the light that reaches it straight from the sky; the light that reaches it
/// after bouncing off the stones; and the light that reaches it by way of the ground, to scale by how
/// pale the ground is. On the ground's map, the first of these is below nothing under a stone.
constant int transferSize = harmonicCount + 2 * bounceCount;
constant int bouncedOff = harmonicCount;
constant int byGround = harmonicCount + bounceCount;
constant uint keySamples = 32;

/// The real spherical harmonics toward `d`, with straight up as their pole, each times `scale`. Sloan's
/// recurrence, with the powers of (x + iy) standing in for the sines and cosines around the pole.
static void harmonics(float3 d, constant float *scale, thread float *y) {
    float px = d.x, py = -d.z, pz = d.y;
    float c = 1, s = 0, pmm = 1;
    for (int m = 0; m < harmonicOrder; m++) {
        if (m > 0) {
            float nc = c * px - s * py;
            s = c * py + s * px;
            c = nc;
            pmm *= float(2 * m - 1);
        }
        float before = 0, last = 0;
        for (int l = m; l < harmonicOrder; l++) {
            float p = l == m ? pmm : l == m + 1 ? pz * float(2 * m + 1) * pmm
                : (float(2 * l - 1) * pz * last - float(l + m - 1) * before) / float(l - m);
            before = last;
            last = p;
            int i = l * l + l;
            if (m == 0) {
                y[i] = scale[i] * p;
            } else {
                y[i + m] = scale[i + m] * p * c;
                y[i - m] = scale[i - m] * p * s;
            }
        }
    }
}

/// The `k`th of `n` directions spread evenly over the hemisphere around `normal`, more of them face on,
/// as light falls on a matte surface: a spiral, turned by `turn` of the way around.
static float3 spreadOver(float3 normal, uint k, uint n, float turn) {
    float v = (float(k) + 0.5) / float(n);
    float phi = 2 * M_PI_F * fract(float(k) * 0.6180339887 + turn);
    float r = sqrt(v);
    float3 t, b;
    basis(normal, t, b);
    return t * (r * cos(phi)) + b * (r * sin(phi)) + normal * sqrt(max(0.0, 1 - v));
}

/// The `k`th of `n` directions spread evenly across the key light's disc: a spiral, turned by `turn`.
static float3 acrossKey(constant TraceUniforms &u, uint k, uint n, float turn) {
    float v = (float(k) + 0.5) / float(n);
    float c = 1 - v * (1 - u.key.w), s = sqrt(max(0.0, 1 - c * c));
    float phi = 2 * M_PI_F * fract(float(k) * 0.6180339887 + turn);
    float3 t, b;
    basis(u.key.xyz, t, b);
    return t * (s * cos(phi)) + b * (s * sin(phi)) + u.key.xyz * c;
}

struct BakeSettings {
    /// Which round this is (0: the sky's light only, each round after adds a bounce), how many directions
    /// each point looks in, and which points this dispatch takes.
    uint round;
    uint samples;
    uint first;
    uint count;
    /// Where each stone's vertices begin, and how many there are in all.
    uint4 bases;
    /// How much light the stones throw back, on average, and how many points a side the ground's map has.
    float stoneAlbedo;
    uint groundSize;
    uint2 unused;
};

/// All the light that reaches the ground's map at `xz` (in the stack's own frame), as far as bounced
/// light holds it, weighed between the four nearest points.
static void groundTransferAt(float2 xz, device const half *ground, uint size, thread float *a) {
    float2 m = xz / (groundMapReach + abs(xz));
    float2 g = (m * 0.5 + 0.5) * float(size) - 0.5;
    int2 i0 = int2(floor(g));
    float2 f = g - float2(i0);
    for (int j = 0; j < bounceCount; j++) {
        a[j] = 0;
    }
    for (int q = 0; q < 4; q++) {
        int2 c = clamp(i0 + int2(q & 1, q >> 1), int2(0), int2(int(size) - 1));
        float w = ((q & 1) ? f.x : 1 - f.x) * ((q >> 1) ? f.y : 1 - f.y);
        device const half *t = ground + (uint(c.y) * size + uint(c.x)) * transferSize;
        if (t[0] < 0) {
            continue;
        }
        for (int j = 0; j < bounceCount; j++) {
            a[j] += w * (float(t[j]) + float(t[bouncedOff + j]));
        }
    }
}

/// All the light that reaches a stone where `hit` met it, and the share of it that comes by way of the
/// ground, as far as bounced light holds them, weighed between its triangle's corners. False where the
/// ray met the stone from inside.
static bool stoneTransferAt(Hit hit, float3 direction, thread const Geometry &g, device const half *stones,
                            thread float *a, thread float *b) {
    uint i0 = g.indices[hit.triangle * 3], i1 = g.indices[hit.triangle * 3 + 1], i2 = g.indices[hit.triangle * 3 + 2];
    float3 w = float3(1 - hit.barycentrics.x - hit.barycentrics.y, hit.barycentrics.x, hit.barycentrics.y);
    constant TraceStone &stone = g.stones[hit.what];
    float3x3 rotation = float3x3(stone.toWorld[0].xyz, stone.toWorld[1].xyz, stone.toWorld[2].xyz);
    float3 normal = rotation * (g.normals[i0].xyz * w.x + g.normals[i1].xyz * w.y + g.normals[i2].xyz * w.z);
    if (dot(normal, direction) > 0) {
        return false;
    }
    device const half *t[3] = { stones + i0 * transferSize, stones + i1 * transferSize, stones + i2 * transferSize };
    for (int j = 0; j < bounceCount; j++) {
        a[j] = 0;
        b[j] = 0;
    }
    for (int c = 0; c < 3; c++) {
        for (int j = 0; j < bounceCount; j++) {
            a[j] += w[c] * (float(t[c][j]) + float(t[c][bouncedOff + j]));
            b[j] += w[c] * float(t[c][byGround + j]);
        }
    }
    return true;
}

/// One round of working out what reaches each stone vertex: the sky straight, and from this round on,
/// what the last round found on whatever else each direction meets, the stones or the ground, thrown
/// back. A vertex buried in the ground gets nothing.
kernel void bakeStonesKernel(uint gid [[thread_position_in_grid]],
                             constant BakeSettings &b [[buffer(0)]],
                             constant TraceStone *stones [[buffer(1)]],
                             device const TraceNode *nodes [[buffer(3)]],
                             device const float4 *triangles [[buffer(4)]],
                             device const uint *indices [[buffer(5)]],
                             device const float4 *normals [[buffer(6)]],
                             device const float4 *tangents [[buffer(7)]],
                             device const float4 *bitangents [[buffer(8)]],
                             device const float2 *coordinates [[buffer(9)]],
                             device const float4 *positions [[buffer(15)]],
#if !SOFTWARE_RAYS
                             instance_acceleration_structure scene [[buffer(16)]],
#endif
                             constant float *scale [[buffer(17)]],
                             device const half *stonesBefore [[buffer(18)]],
                             device const half *groundBefore [[buffer(19)]],
                             device half *stonesAfter [[buffer(20)]]) {
    uint v = b.first + gid;
    if (gid >= b.count || v >= b.bases.w) {
        return;
    }
#if SOFTWARE_RAYS
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions };
#else
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions, scene };
#endif
    int k = v < b.bases.y ? 0 : v < b.bases.z ? 1 : 2;
    constant TraceStone &stone = stones[k];
    float3x3 rotation = float3x3(stone.toWorld[0].xyz, stone.toWorld[1].xyz, stone.toWorld[2].xyz);
    float3 p = (stone.toWorld * float4(positions[v].xyz, 1)).xyz;
    float3 n = normalize(rotation * normals[v].xyz);
    float3 start = p + n * 3e-5;
    float sky[harmonicCount], y[harmonicCount], off[bounceCount], ground[bounceCount], a[bounceCount], c[bounceCount];
    for (int j = 0; j < harmonicCount; j++) {
        sky[j] = 0;
    }
    for (int j = 0; j < bounceCount; j++) {
        off[j] = 0;
        ground[j] = 0;
    }
    if (p.y > 0) {
        float turn = float(hashed(v * 7919u + 13u)) / 4294967296.0;
        for (uint s = 0; s < b.samples; s++) {
            float3 d = spreadOver(n, s, b.samples, turn);
            Hit hit = trace(start, d, INFINITY, g, false);
            if (hit.what < 0) {
                if (d.y > 0) {
                    harmonics(d, scale, y);
                    for (int j = 0; j < harmonicCount; j++) {
                        sky[j] += M_PI_F * y[j];
                    }
                }
            } else if (b.round > 0) {
                if (hit.what == 3) {
                    groundTransferAt((start + d * hit.t).xz, groundBefore, b.groundSize, a);
                    for (int j = 0; j < bounceCount; j++) {
                        ground[j] += a[j];
                    }
                } else if (stoneTransferAt(hit, d, g, stonesBefore, a, c)) {
                    for (int j = 0; j < bounceCount; j++) {
                        off[j] += b.stoneAlbedo * a[j];
                        ground[j] += b.stoneAlbedo * c[j];
                    }
                }
            }
        }
    }
    float share = 1.0 / float(b.samples);
    device half *out = stonesAfter + v * transferSize;
    for (int j = 0; j < harmonicCount; j++) {
        out[j] = half(sky[j] * share);
    }
    for (int j = 0; j < bounceCount; j++) {
        out[bouncedOff + j] = half(off[j] * share);
        out[byGround + j] = half(ground[j] * share);
    }
}

/// The same for each point of the ground's map around the stack, in its own frame: the sky straight, and
/// what the stones throw down. A point under a stone is marked.
kernel void bakeGroundKernel(uint2 texel [[thread_position_in_grid]],
                             constant BakeSettings &b [[buffer(0)]],
                             constant TraceStone *stones [[buffer(1)]],
                             device const TraceNode *nodes [[buffer(3)]],
                             device const float4 *triangles [[buffer(4)]],
                             device const uint *indices [[buffer(5)]],
                             device const float4 *normals [[buffer(6)]],
                             device const float4 *tangents [[buffer(7)]],
                             device const float4 *bitangents [[buffer(8)]],
                             device const float2 *coordinates [[buffer(9)]],
                             device const float4 *positions [[buffer(15)]],
#if !SOFTWARE_RAYS
                             instance_acceleration_structure scene [[buffer(16)]],
#endif
                             constant float *scale [[buffer(17)]],
                             device const half *stonesBefore [[buffer(18)]],
                             device half *groundAfter [[buffer(20)]]) {
    uint size = b.groundSize;
    uint row = b.first + texel.y;
    if (texel.x >= size || row >= size || texel.y >= b.count) {
        return;
    }
#if SOFTWARE_RAYS
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions };
#else
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions, scene };
#endif
    float2 m = (float2(texel.x, row) + 0.5) / float(size) * 2 - 1;
    float2 xz = groundMapReach * m / max(1 - abs(m), 1e-4);
    float3 start = float3(xz.x, 2e-4, xz.y);
    float sky[harmonicCount], y[harmonicCount], off[bounceCount], ground[bounceCount], a[bounceCount], c[bounceCount];
    for (int j = 0; j < harmonicCount; j++) {
        sky[j] = 0;
    }
    for (int j = 0; j < bounceCount; j++) {
        off[j] = 0;
        ground[j] = 0;
    }
    device half *out = groundAfter + (row * size + texel.x) * transferSize;
    // Under a stone, it's never seen; it's marked, so what's around it isn't darkened by it.
    Hit above = trace(start, float3(0, 1, 0), INFINITY, g, false);
    if (above.what >= 0 && above.what < 3 && !stoneTransferAt(above, float3(0, 1, 0), g, stonesBefore, a, c)) {
        for (int j = 0; j < transferSize; j++) {
            out[j] = 0;
        }
        out[0] = -1;
        return;
    }
    float turn = float(hashed(row * 104729u + texel.x * 7919u + 31u)) / 4294967296.0;
    for (uint s = 0; s < b.samples; s++) {
        float3 d = spreadOver(float3(0, 1, 0), s, b.samples, turn);
        Hit hit = trace(start, d, INFINITY, g, false);
        if (hit.what < 0) {
            harmonics(d, scale, y);
            for (int j = 0; j < harmonicCount; j++) {
                sky[j] += M_PI_F * y[j];
            }
        } else if (hit.what < 3 && b.round > 0 && stoneTransferAt(hit, d, g, stonesBefore, a, c)) {
            for (int j = 0; j < bounceCount; j++) {
                off[j] += b.stoneAlbedo * a[j];
                ground[j] += b.stoneAlbedo * c[j];
            }
        }
    }
    float share = 1.0 / float(b.samples);
    for (int j = 0; j < harmonicCount; j++) {
        out[j] = half(sky[j] * share);
    }
    for (int j = 0; j < bounceCount; j++) {
        out[bouncedOff + j] = half(off[j] * share);
        out[byGround + j] = half(ground[j] * share);
    }
}

/// A stone vertex buried in the ground takes what its neighbors above the ground keep, so the light on a
/// stone where it meets the ground carries on from just above, instead of fading to nothing across the
/// whole triangle.
kernel void fillBuriedKernel(uint triangle [[thread_position_in_grid]],
                             constant uint &triangles [[buffer(0)]],
                             constant TraceStone *stones [[buffer(1)]],
                             device const uint *indices [[buffer(5)]],
                             device const float4 *positions [[buffer(15)]],
                             constant uint4 &bases [[buffer(19)]],
                             device half *transfer [[buffer(20)]]) {
    if (triangle >= triangles) {
        return;
    }
    uint v[3] = { indices[triangle * 3], indices[triangle * 3 + 1], indices[triangle * 3 + 2] };
    bool buried[3];
    int open = 0;
    for (int c = 0; c < 3; c++) {
        int k = v[c] < bases.y ? 0 : v[c] < bases.z ? 1 : 2;
        buried[c] = (stones[k].toWorld * float4(positions[v[c]].xyz, 1)).y <= 0;
        open += buried[c] ? 0 : 1;
    }
    if (open == 0 || open == 3) {
        return;
    }
    for (int j = 0; j < transferSize; j++) {
        float sum = 0;
        for (int c = 0; c < 3; c++) {
            sum += buried[c] ? 0 : float(transfer[v[c] * transferSize + j]);
        }
        for (int c = 0; c < 3; c++) {
            if (buried[c]) {
                transfer[v[c] * transferSize + j] = half(sum / float(open));
            }
        }
    }
}

/// The light around the stack now, as harmonics in its own frame: the sky and its glow, the key light,
/// and how pale the ground is, which scales the ground's share.
struct BakedLight {
    float4 rest[harmonicCount];
    float4 key[harmonicCount];
    float4 groundAlbedo;
    /// How much of the light the stones were worked out to throw onto each other they throw now (x), as
    /// they're darker or paler than then.
    float4 stoneBounce;
};

/// The light falling on a point that keeps `t`: the sky's and the glow's straight light, and of them and
/// the key light (whose straight light is traced), what comes bounced off the stones and by way of the
/// ground. Between two of the stones' poses, `blend` of the way from the first's to the second's.
static float3 bakedLight(device const half *from, device const half *to, float blend, constant BakedLight &light) {
    float3 e = 0;
    for (int j = 0; j < harmonicCount; j++) {
        e += mix(float(from[j]), float(to[j]), blend) * light.rest[j].rgb;
    }
    for (int j = 0; j < bounceCount; j++) {
        float off = mix(float(from[bouncedOff + j]), float(to[bouncedOff + j]), blend);
        float ground = mix(float(from[byGround + j]), float(to[byGround + j]), blend);
        e += (off * light.stoneBounce.x + ground * light.groundAlbedo.rgb) * (light.rest[j].rgb + light.key[j].rgb);
    }
    return e;
}

/// The light falling on each stone vertex now, where the stones are: what it keeps, and the key light's
/// straight light, its shadows traced the same few directions across it every frame, so nothing
/// flickers; and how much of the key light and of the sky it sees, for its sheen.
kernel void stoneLightKernel(uint v [[thread_position_in_grid]],
                             constant TraceUniforms &u [[buffer(0)]],
                             constant TraceStone *stones [[buffer(1)]],
                             device const TraceNode *nodes [[buffer(3)]],
                             device const float4 *triangles [[buffer(4)]],
                             device const uint *indices [[buffer(5)]],
                             device const float4 *normals [[buffer(6)]],
                             device const float4 *tangents [[buffer(7)]],
                             device const float4 *bitangents [[buffer(8)]],
                             device const float2 *coordinates [[buffer(9)]],
                             device const float4 *positions [[buffer(15)]],
#if !SOFTWARE_RAYS
                             instance_acceleration_structure scene [[buffer(16)]],
#endif
                             constant BakedLight &light [[buffer(17)]],
                             device const half *transfer [[buffer(18)]],
                             constant uint4 &bases [[buffer(19)]],
                             device float4 *lit [[buffer(20)]],
                             device const half *towards [[buffer(21)]],
                             constant float &blend [[buffer(22)]]) {
    if (v >= bases.w) {
        return;
    }
#if SOFTWARE_RAYS
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions };
#else
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions, scene };
#endif
    device const half *from = transfer + v * transferSize, *to = towards + v * transferSize;
    float3 e = bakedLight(from, to, blend, light);
    float3 sky = 0;
    for (int j = 0; j < harmonicCount; j++) {
        sky += mix(float(from[j]), float(to[j]), blend) * light.rest[j].rgb;
    }
    int k = v < bases.y ? 0 : v < bases.z ? 1 : 2;
    constant TraceStone &stone = stones[k];
    float3x3 rotation = float3x3(stone.toWorld[0].xyz, stone.toWorld[1].xyz, stone.toWorld[2].xyz);
    float3 p = (stone.toWorld * float4(positions[v].xyz, 1)).xyz;
    float3 n = normalize(rotation * normals[v].xyz);
    float3 start = p + n * 3e-5;
    float seen = 0, facing = 0, falling = 0;
    float turn = float(hashed(v * 7919u + 13u)) / 4294967296.0;
    for (uint s = 0; s < keySamples && p.y > 0; s++) {
        float3 d = acrossKey(u, s, keySamples, turn);
        float c = dot(n, d);
        if (c <= 0) {
            continue;
        }
        facing += 1;
        if (!blocked(start, d, g)) {
            seen += 1;
            falling += c;
        }
    }
    e += u.keyRadiance.rgb * (2 * M_PI_F * (1 - u.key.w)) * falling / float(keySamples);
    lit[2 * v] = float4(max(e, 0.0), facing > 0 ? seen / facing : 0);
    lit[2 * v + 1] = float4(luminance(sky), 0, 0, 0);
}

/// The light falling on each point of the ground's map in the stack's own frame, from what it keeps.
kernel void groundHarmonicsKernel(uint2 texel [[thread_position_in_grid]],
                                  constant BakedLight &light [[buffer(17)]],
                                  device const half *transfer [[buffer(18)]],
                                  device const half *towards [[buffer(21)]],
                                  constant float &blend [[buffer(22)]],
                                  texture2d<float, access::write> out [[texture(0)]]) {
    uint size = out.get_width();
    if (texel.x >= size || texel.y >= size) {
        return;
    }
    uint i = (texel.y * size + texel.x) * transferSize;
    device const half *from = transfer + i, *to = towards + i;
    out.write(from[0] < 0 || to[0] < 0 ? float4(0) : float4(max(bakedLight(from, to, blend, light), 0.0), 1), texel);
}

/// The key light's straight light on each point of the ground's map in the world, its shadows traced
/// the same few directions across it every frame.
kernel void groundKeyKernel(uint2 texel [[thread_position_in_grid]],
                            constant TraceUniforms &u [[buffer(0)]],
                            constant TraceStone *stones [[buffer(1)]],
                            device const TraceNode *nodes [[buffer(3)]],
                            device const float4 *triangles [[buffer(4)]],
                            device const uint *indices [[buffer(5)]],
                            device const float4 *normals [[buffer(6)]],
                            device const float4 *tangents [[buffer(7)]],
                            device const float4 *bitangents [[buffer(8)]],
                            device const float2 *coordinates [[buffer(9)]],
                            device const float4 *positions [[buffer(15)]],
#if !SOFTWARE_RAYS
                            instance_acceleration_structure scene [[buffer(16)]],
#endif
                            texture2d<float, access::write> out [[texture(0)]]) {
    uint size = out.get_width();
    if (texel.x >= size || texel.y >= size) {
        return;
    }
#if SOFTWARE_RAYS
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions };
#else
    Geometry g = { nodes, triangles, indices, normals, tangents, bitangents, coordinates, stones, positions, scene };
#endif
    float2 m = (float2(texel) + 0.5) / float(size) * 2 - 1;
    float2 xz = fromGroundMap(m, u);
    float3 start = float3(xz.x, 2e-4, xz.y);
    Hit above = trace(start, float3(0, 1, 0), INFINITY, g, false);
    if (above.what >= 0 && above.what < 3) {
        uint i0 = g.indices[above.triangle * 3], i1 = g.indices[above.triangle * 3 + 1], i2 = g.indices[above.triangle * 3 + 2];
        float3 w = float3(1 - above.barycentrics.x - above.barycentrics.y, above.barycentrics.x, above.barycentrics.y);
        constant TraceStone &stone = g.stones[above.what];
        float3x3 rotation = float3x3(stone.toWorld[0].xyz, stone.toWorld[1].xyz, stone.toWorld[2].xyz);
        if ((rotation * (g.normals[i0].xyz * w.x + g.normals[i1].xyz * w.y + g.normals[i2].xyz * w.z)).y > 0) {
            out.write(float4(0), texel);
            return;
        }
    }
    float turn = float(hashed(texel.y * 104729u + texel.x * 7919u + 31u)) / 4294967296.0;
    float falling = 0;
    for (uint s = 0; s < keySamples; s++) {
        float3 d = acrossKey(u, s, keySamples, turn);
        if (d.y > 0 && !blocked(start, d, g)) {
            falling += d.y;
        }
    }
    out.write(float4(u.keyRadiance.rgb * (2 * M_PI_F * (1 - u.key.w)) * falling / float(keySamples), 1), texel);
}

/// `map` at `at`, weighed between the nearest of its points that aren't under a stone (alpha 1), so the
/// ground where it meets a stone isn't darkened by what's under it; further out if they all are.
static float3 openSample(texture2d<float> map, float2 at) {
    int2 size = int2(map.get_width(), map.get_height());
    float2 g = at * float2(size) - 0.5;
    int2 i0 = int2(floor(g));
    float2 f = g - float2(i0);
    for (int reach = 0; reach < 3; reach++) {
        float3 sum = 0;
        float total = 0;
        for (int y = -reach; y <= 1 + reach; y++) {
            for (int x = -reach; x <= 1 + reach; x++) {
                int2 c = clamp(i0 + int2(x, y), int2(0), size - 1);
                float4 v = map.read(uint2(c));
                float wx = x <= 0 ? 1 - f.x + float(x) : f.x - float(x - 1);
                float wy = y <= 0 ? 1 - f.y + float(y) : f.y - float(y - 1);
                float w = max(wx, 0.05) * max(wy, 0.05) * v.a;
                sum += v.rgb * w;
                total += w;
            }
        }
        if (total > 1e-4) {
            return sum / total;
        }
    }
    return 0;
}

/// The ground's map in the world: what the ground keeps, in the stack's frame turned by `turn` (its
/// cosine and sine), and the key light's straight light.
kernel void groundBakedKernel(uint2 texel [[thread_position_in_grid]],
                              constant TraceUniforms &u [[buffer(0)]],
                              constant float2 &turn [[buffer(1)]],
                              texture2d<float> kept [[texture(0)]],
                              texture2d<float> key [[texture(1)]],
                              texture2d<float, access::write> map [[texture(2)]]) {
    uint size = map.get_width();
    if (texel.x >= size || texel.y >= size) {
        return;
    }
    float2 m = (float2(texel) + 0.5) / float(size) * 2 - 1;
    float2 xz = fromGroundMap(m, u) - u.stack.xz;
    float2 local = float2(xz.x * turn.x - xz.y * turn.y, xz.x * turn.y + xz.y * turn.x);
    float2 at = local / (groundMapReach + abs(local)) * 0.5 + 0.5;
    map.write(float4(openSample(kept, at) + openSample(key, m * 0.5 + 0.5), 1), texel);
}

struct StoneFragmentIn {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 across;
    float3 along;
    float2 uv;
    /// The light falling on it, and how much of the key light it sees; how much of the sky it sees.
    float4 light;
    float sky;
};

/// A stone's corner, where `toWorld` puts it, seen with the stones' camera in the rectangle of the view
/// the stones take; with the light falling on it.
vertex StoneFragmentIn stoneVertex(uint v [[vertex_id]],
                                   constant TraceUniforms &u [[buffer(0)]],
                                   constant float4x4 &toWorld [[buffer(1)]],
                                   device const float4 *positions [[buffer(2)]],
                                   device const float4 *normals [[buffer(3)]],
                                   device const float4 *tangents [[buffer(4)]],
                                   device const float4 *bitangents [[buffer(5)]],
                                   device const float2 *coordinates [[buffer(6)]],
                                   device const float4 *lit [[buffer(7)]]) {
    StoneFragmentIn out;
    float3x3 rotation = float3x3(toWorld[0].xyz, toWorld[1].xyz, toWorld[2].xyz);
    out.world = (toWorld * float4(positions[v].xyz, 1)).xyz;
    out.normal = rotation * normals[v].xyz;
    out.across = rotation * tangents[v].xyz;
    out.along = rotation * bitangents[v].xyz;
    out.uv = coordinates[v];
    out.light = lit[2 * v];
    out.sky = lit[2 * v + 1].x;
    float3 d = out.world - u.eye.xyz;
    float z = max(dot(d, u.forward.xyz), 1e-3);
    float2 points = u.center + u.focal * float2(dot(d, u.right.xyz), -dot(d, u.up.xyz)) / z;
    float2 pixel = points * u.pixelsPerPoint - float2(float(u.regionLeft), float(u.regionTop));
    float2 ndc = float2(pixel.x / float(u.regionWidth) * 2 - 1, 1 - pixel.y / float(u.regionHeight) * 2);
    out.position = float4(ndc * z, 0.05, z);
    return out;
}

/// What the environment's harmonics give toward `d`, each band `l` scaled by `bands[l]`.
static float3 environmentToward(float3 d, constant float4 *environment, constant float *scale, thread const float *bands, int count) {
    float y[harmonicCount];
    harmonics(d, scale, y);
    float3 sum = 0;
    for (int l = 0; l < harmonicOrder; l++) {
        for (int m = -l; m <= l; m++) {
            int i = l * l + l + m;
            if (i < count) {
                sum += environment[i].rgb * y[i] * bands[l];
            }
        }
    }
    return sum;
}

/// A stone's surface: the light falling on it as worked out at its corners, turned to the fine relief of
/// its grain; its sheen, the sky in it blurred as rough as it is, as much as it sees of the sky; and the
/// key light's highlight, as much as it sees of the key light. Linear light.
fragment half4 stoneFragment(StoneFragmentIn in [[stage_in]],
                                constant TraceUniforms &u [[buffer(0)]],
                                constant float4 *environment [[buffer(1)]],
                                constant float *scale [[buffer(2)]],
                                texture2d<float> color [[texture(0)]],
                                texture2d<float> relief [[texture(1)]]) {
    // The ground hides what's sunk into it.
    if (in.world.y < 0) {
        discard_fragment();
    }
    constexpr sampler tiled(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    float3 n = normalize(in.normal);
    float3 toEye = normalize(u.eye.xyz - in.world);
    float3 across = in.across, along = in.along;
    if (length_squared(across) < 1e-12 || length_squared(along) < 1e-12) {
        basis(n, across, along);
    }
    float3 grain = color.sample(tiled, in.uv).rgb;
    float3 tilt = relief.sample(tiled, in.uv).rgb;
    float2 slope = (tilt.rg - 0.5) * u.reliefDepth;
    float3 shaded = normalize(n - normalize(across) * slope.x + normalize(along) * slope.y);
    if (dot(shaded, toEye) < 0.02) {
        shaded = normalize(shaded + toEye * (0.02 - dot(shaded, toEye)));
    }
    float3 albedo = grain * u.stoneAlbedo.rgb;
    float roughness = u.roughness * (0.4 + 1.2 * tilt.b);

    // Light from all around falling on the relief: the same light as at the corners, as much more or
    // less as the relief turns the surface toward or away from the brighter sky.
    const float cosineBands[harmonicOrder] = { M_PI_F, 2 * M_PI_F / 3, M_PI_F / 4, 0, 0, 0 };
    float3 tilted = environmentToward(shaded, environment, scale, cosineBands, 9);
    float3 straight = environmentToward(n, environment, scale, cosineBands, 9);
    float3 falling = in.light.rgb * clamp(tilted / max(straight, 1e-4), 0.5, 1.5);

    float nv = saturate(dot(shaded, toEye));
    float f0 = 0.08 * u.specular;
    float2 share = reflectedShare(nv, roughness);
    float sheen = f0 * share.x + share.y;
    float3 light = albedo / M_PI_F * falling * (1 - sheen);

    // The sky in it, blurred as rough as it is.
    float a = roughness * roughness;
    float spread = 2 / max(a * a, 1e-3) - 2;
    float blur[harmonicOrder];
    for (int l = 0; l < harmonicOrder; l++) {
        blur[l] = exp(-float(l * l) / (2 * spread));
    }
    float3 reflected = environmentToward(reflect(-toEye, shaded), environment, scale, blur, harmonicCount);
    // As much of it as it sees of the sky: from what of the sky's light reaches it straight, against
    // what an open surface facing the same way gets from all around, half of it from the ground.
    light += max(reflected, 0.0) * sheen * saturate(1.5 * in.sky / max(luminance(straight), 1e-4));

    // The key light's highlight: a small disc of light, so a highlight a little broader than a point's.
    float nl = dot(shaded, u.key.xyz);
    if (nl > 0 && in.light.a > 0) {
        float3 h = normalize(u.key.xyz + toEye);
        float radius = acos(u.key.w);
        float wide = saturate(a + radius * 0.5), a2 = max(wide * wide, 1e-6);
        float highlight = ggx(saturate(dot(shaded, h)), a2) * visibility(nv, nl, a2) * schlick(f0, saturate(dot(toEye, h)))
            * (a * a) / max(wide * wide, 1e-6);
        light += highlight * nl * u.keyRadiance.rgb * (2 * M_PI_F * (1 - u.key.w)) * in.light.a;
    }
    return half4(half3(max(light, 0.0)), 1);
}

/// The scene as the screen shows it, with the stones drawn rather than traced: the backdrop, the stones
/// over it where they are; exposed, with highlights rolling off softly, encoded, with the paper's grain.
fragment half4 bakedDisplayFragment(DisplayVertex in [[stage_in]], constant TraceUniforms &u [[buffer(0)]],
                                    texture2d<float> backdrop [[texture(0)]],
                                    texture2d<float> stones [[texture(1)]],
                                    texture2d<float> grain [[texture(2)]]) {
    constexpr sampler tiled(filter::linear, address::repeat);
    uint2 pixel = uint2(in.position.xy);
    float3 light = backdrop.read(pixel).rgb;
    int2 inside = int2(pixel) - int2(int(u.regionLeft), int(u.regionTop));
    if (inside.x >= 0 && inside.y >= 0 && inside.x < int(u.regionWidth) && inside.y < int(u.regionHeight)) {
        float4 stone = stones.read(uint2(inside));
        light = light * (1 - stone.a) + stone.rgb;
    }
    light *= u.exposure;
    float3 over = max(light - 0.8, 0.0);
    light = min(light, 0.8) + 0.2 * (1 - exp(-over / 0.2));
    float3 base = encoded(saturate(light));
    float g = grain.sample(tiled, in.position.xy / u.pixelsPerPoint / 100).r;
    float3 lit = g <= 0.5 ? base - (1 - 2 * g) * base * (1 - base)
        : base + (2 * g - 1) * (select(sqrt(base), ((16 * base - 12) * base + 4) * base, base <= 0.25) - base);
    return half4(half3(mix(base, lit, u.grainOpacity)), 1);
}

/// The scene with no stones in it, as the screen shows it: the sky, and the ground as open to it as it is
/// away from them, seen through the mist, all worked out in one go; exposed, encoded, with the paper's
/// grain. Behind the screens beside the home screen, so they're the same scene.
fragment half4 openSceneFragment(DisplayVertex in [[stage_in]], constant TraceUniforms &u [[buffer(0)]],
                                 texture2d<float> grain [[texture(0)]]) {
    constexpr sampler tiled(filter::linear, address::repeat);
    float2 p = in.position.xy / u.pixelsPerPoint;
    float3 direction = normalize(u.forward.xyz + (p.x - u.center.x) / u.focal * u.right.xyz
                                 + (u.center.y - p.y) / u.focal * u.up.xyz);
    float t = direction.y < -1e-7 ? -u.eye.y / direction.y : INFINITY;
    float through;
    float3 fogged = throughFog(u.eye.xyz, direction, t, u, 0.5, through);
    float3 light;
    if (isinf(t)) {
        light = skySeen(direction, u) * through + fogged;
    } else {
        Surface ground = groundSurface(u.eye.xyz + direction * t, u);
        light = ground.albedo / M_PI_F * (u.skyIrradiance.rgb + u.keyIrradiance.rgb) * through + fogged;
    }
    light *= u.exposure;
    float3 over = max(light - 0.8, 0.0);
    light = min(light, 0.8) + 0.2 * (1 - exp(-over / 0.2));
    float3 base = encoded(saturate(light));
    float g = grain.sample(tiled, in.position.xy / u.pixelsPerPoint / 100).r;
    float3 lit = g <= 0.5 ? base - (1 - 2 * g) * base * (1 - base)
        : base + (2 * g - 1) * (select(sqrt(base), ((16 * base - 12) * base + 4) * base, base <= 0.25) - base);
    return half4(half3(mix(base, lit, u.grainOpacity)), 1);
}
