#include <metal_stdlib>
using namespace metal;

struct Light {
    float4 positionOrDirection;
    float4 color;
    float4 params;          // x: type 0 sun / 1 point / 2 ambient / 3 spot
    float4 direction;       // xyz: normalized spot direction
    float4 spotParams;      // x: outer cosine, y: inner cosine
};

struct SceneUniforms {
    float4x4 viewProjection;
    float4x4 view;
    float4x4 model;
    float4x4 normalMatrix;
    float4 lightDirection;
    float4 lightColor;
    float4 ambientColor;
    float4 cameraPosition;
    float4 params;          // x: groundY, y: gridSpacing, z: edgeScale, w: style index
    float4 lightParams;     // x: ambient, y: fill, z: rim, w: exposure
    float4 lightCount;      // x: active lights, y: ambient strength, z: exposure, w: toon steps
    float4 viewportSize;    // x/y: drawable size
    float4 gradeParams;     // x: contrast, y: bloom, z: vignette, w: reflection
    float4 toonParams;      // x: terminator softness, y: shadow lift, z: rim, w: reserved
    float4 toonShadowTint;  // rgb: shadow tint, a: tint strength
    float4 worldParams;     // x: wrap scattering, y: world intensity
    float4 worldSkyColor;
    float4 worldGroundColor;
    Light lights[8];
};

struct MaterialUniforms {
    float4 diffuse;
    float4 specular;        // rgb: color, w: power
    float4 ambient;
    float4 edgeColor;
    float4 textureTint;
    float4 sphereTint;
    float4 toonTint;
    float edgeSize;
    float alphaTest;
    int sphereMode;
    uint flags;
    int renderMode;
};

constant uint kFlagHasTexture = 1;
constant uint kFlagHasSphere = 2;
constant uint kFlagHasToon = 4;
constant uint kFlagDoubleSided = 8;
constant uint kFlagOpaque = 16;

struct MeshVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float3 viewNormal;
    float2 uv;
    float edgeScale;
};

// MARK: - Mesh

vertex MeshVertexOut mmd_mesh_vertex(uint vid [[vertex_id]],
                                     device const float3 *positions [[buffer(0)]],
                                     device const float3 *normals [[buffer(1)]],
                                     device const float2 *uvs [[buffer(2)]],
                                     device const uint4 *boneIndices [[buffer(3)]],
                                     device const float4 *weights [[buffer(4)]],
                                     device const float *edgeScales [[buffer(5)]],
                                     constant SceneUniforms &scene [[buffer(6)]],
                                     device const float4x4 *palette [[buffer(7)]]) {
    uint4 bi = boneIndices[vid];
    float4 w = weights[vid];
    float3 position = positions[vid];
    float3 normal = normals[vid];

    float4 skinned = w.x * (palette[bi.x] * float4(position, 1.0))
                   + w.y * (palette[bi.y] * float4(position, 1.0))
                   + w.z * (palette[bi.z] * float4(position, 1.0))
                   + w.w * (palette[bi.w] * float4(position, 1.0));
    float3 skinnedNormal = w.x * (palette[bi.x] * float4(normal, 0.0)).xyz
                         + w.y * (palette[bi.y] * float4(normal, 0.0)).xyz
                         + w.z * (palette[bi.z] * float4(normal, 0.0)).xyz
                         + w.w * (palette[bi.w] * float4(normal, 0.0)).xyz;

    float4 world = scene.model * float4(skinned.xyz, 1.0);
    float3 worldNormal = normalize((scene.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

    MeshVertexOut out;
    out.position = scene.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = worldNormal;
    out.viewNormal = normalize((scene.view * float4(worldNormal, 0.0)).xyz);
    out.uv = uvs[vid];
    out.edgeScale = edgeScales[vid];
    return out;
}

fragment float4 mmd_mesh_fragment(MeshVertexOut in [[stage_in]],
                                  bool frontFacing [[front_facing]],
                                  constant SceneUniforms &scene [[buffer(0)]],
                                  constant MaterialUniforms &mat [[buffer(1)]],
                                  texture2d<float> baseMap [[texture(0)]],
                                  texture2d<float> sphereMap [[texture(1)]],
                                  texture2d<float> toonMap [[texture(2)]]) {
    constexpr sampler repeatSampler(address::repeat, filter::linear, mip_filter::linear);
    constexpr sampler clampSampler(address::clamp_to_edge, filter::linear, mip_filter::linear);

    float4 base = mat.diffuse;
    if ((mat.flags & kFlagHasTexture) != 0) {
        float4 texel = baseMap.sample(repeatSampler, in.uv);
        base *= texel;
    }
    base.rgb *= mat.textureTint.rgb;

    float3 N = normalize(in.normal);
    if ((mat.flags & kFlagDoubleSided) != 0 && !frontFacing) {
        N = -N;
    }
    float3 V = normalize(scene.cameraPosition.xyz - in.worldPosition);

    // Sphere maps are a material-level reflection term and must be applied
    // before choosing the shading model; inspection modes still override it.
    if ((mat.flags & kFlagHasSphere) != 0) {
        float2 sphereUV = in.viewNormal.xy;
        sphereUV = sphereUV * 0.5 + 0.5;
        sphereUV.y = 1.0 - sphereUV.y;
        float4 sphere = sphereMap.sample(clampSampler, sphereUV);
        sphere.rgb *= mat.sphereTint.rgb * clamp(scene.gradeParams.w, 0.0, 2.0);
        if (mat.sphereMode == 1) {
            base.rgb *= sphere.rgb;
        } else if (mat.sphereMode == 2 || mat.sphereMode == 3) {
            base.rgb += sphere.rgb;
        }
    }

    float ambientStrength = clamp(scene.lightCount.y, 0.05, 1.0);
    float exposure = clamp(scene.lightCount.z, 0.5, 2.0);
    float3 ambientLight = scene.ambientColor.rgb * ambientStrength;
    float hemisphere = clamp(N.y * 0.5 + 0.5, 0.0, 1.0);
    ambientLight += mix(scene.worldGroundColor.rgb, scene.worldSkyColor.rgb, hemisphere)
                  * scene.worldParams.y;
    float3 directLight = float3(0.0);
    float3 specularSum = float3(0.0);
    float mainNdl = 0.0;

    // Evaluate up to eight user lights. Spot lights include range falloff and
    // a smooth inner/outer cone; world scattering wraps direct light around
    // the terminator instead of introducing another hard shadow.
    bool toonOnly = mat.renderMode == 0;
    bool mainSunSet = false;
    int lightCount = min(8, max(0, int(scene.lightCount.x)));
    for (int i = 0; i < 8; ++i) {
        if (i >= lightCount) { break; }
        Light light = scene.lights[i];
        if (light.params.w < 0.5) { continue; }
        int type = int(light.params.x);
        if (type == 2) {
            ambientLight += light.color.rgb * light.params.y;
            continue;
        }
        if (toonOnly && type != 0) { continue; }
        float3 toLight;
        float attenuation = 1.0;
        if (type == 0) {
            float3 d = light.positionOrDirection.xyz;
            if (length(d) < 0.0001) { continue; }
            toLight = normalize(d);
        } else {
            float3 offset = light.positionOrDirection.xyz - in.worldPosition;
            float dist = length(offset);
            if (dist < 0.0001) { continue; }
            toLight = offset / dist;
            float range = max(light.params.z, 0.01);
            float ratio = clamp(1.0 - dist / range, 0.0, 1.0);
            attenuation = ratio * ratio;
            if (type == 3) {
                float coneDot = dot(-toLight, normalize(light.direction.xyz));
                attenuation *= smoothstep(light.spotParams.x, light.spotParams.y, coneDot);
            }
        }
        float wrap = clamp(scene.worldParams.x, 0.0, 0.85);
        float ndl = max((dot(N, toLight) + wrap) / (1.0 + wrap), 0.0);
        if (toonOnly) {
            if (!mainSunSet) {
                mainNdl = ndl;
                directLight = light.color.rgb * light.params.y * ndl;
                mainSunSet = true;
            }
        } else {
            mainNdl = max(mainNdl, ndl);
            directLight += light.color.rgb * light.params.y * ndl * attenuation;
            float3 halfDirection = normalize(toLight + V);
            specularSum += mat.specular.rgb * light.color.rgb
                         * pow(max(dot(N, halfDirection), 0.0), max(mat.specular.w, 1.0))
                         * light.params.y * attenuation * 0.18;
        }
    }

    // Fallback for scenes that have no explicit light array.
    if (lightCount == 0 || (toonOnly && !mainSunSet)) {
        float3 L = normalize(scene.lightDirection.xyz);
        mainNdl = max(dot(N, L), 0.0);
        directLight = scene.lightColor.rgb * mainNdl;
        ambientLight = scene.ambientColor.rgb * ambientStrength;
    }

    float litRaw = clamp(mainNdl * 0.5 + 0.5, 0.0, 1.0);
    float style = scene.params.w;
    float stepCount = max(2.0, scene.lightCount.w);
    float bandIndex = floor(clamp(mainNdl, 0.0, 1.0) * stepCount);
    float bandValue = mix(0.42, 1.0, bandIndex / max(1.0, stepCount - 1.0));
    // A tiny amount of anti-aliasing around the terminator keeps the edge
    // readable at high resolution without turning the preset back into PBR.
    float toonSoftness = clamp(scene.toonParams.x, 0.0, 0.45);
    bandValue = mix(bandValue, smoothstep(0.0, 1.0, clamp(mainNdl, 0.0, 1.0)), toonSoftness);
    if ((mat.flags & kFlagHasToon) != 0) {
        float ramp = clamp(toonMap.sample(clampSampler, float2(litRaw, 0.5)).r * mat.toonTint.r, 0.12, 1.0);
        // MMD standard honors the authored ramp. Game-style presets bias
        // toward the procedural band so the look stays consistent across
        // models that ship very different toon textures.
        bandValue = mix(bandValue, ramp, 0.35);
    }

    float3 color = base.rgb;
    if (mat.renderMode == 2) {
        // Unlit inspection: preserve the texture exactly.
        color = base.rgb;
    } else if (mat.renderMode == 3) {
        color = N * 0.5 + 0.5;
    } else if (mat.renderMode == 4) {
        float2 grid = floor(in.uv * 12.0);
        float checker = fmod(grid.x + grid.y, 2.0);
        color = base.rgb * (0.35 + checker * 0.45) + float3(0.08, 0.18, 0.24);
    } else if (mat.renderMode == 5) {
        color = float3(0.20, 0.80, 1.0);
    } else if (mat.renderMode == 1) {
        // Realistic: all direct lights + a subtle fill/rim term and specular.
        float3 L = normalize(scene.lightDirection.xyz);
        float3 fillDirection = normalize(float3(-L.x, 0.30, -L.z));
        float fill = max(dot(N, fillDirection), 0.0) * clamp(scene.lightParams.y, 0.0, 1.0);
        float rim = pow(1.0 - max(dot(N, V), 0.0), 2.0) * clamp(scene.lightParams.z, 0.0, 1.0);
        color = base.rgb * (ambientLight * 0.72 + directLight * 0.85
                            + scene.lightColor.rgb * fill * 0.18
                            + scene.lightColor.rgb * rim * 0.30);
        color += mat.specular.rgb * pow(max(dot(N, normalize(L + V)), 0.0),
                                        max(mat.specular.w, 1.0)) * 0.35 + specularSum;
    } else {
        // Toon presets. The game looks share one quantized key light and
        // differ in shadow temperature, terminator softness, rim and
        // contrast. No PBR specular, fill wash or broad realistic rim is
        // applied here.
        float shadowLift = clamp(scene.toonParams.y, 0.0, 1.0);
        float rimAmount = clamp(scene.toonParams.z, 0.0, 1.0);
        float tintStrength = clamp(scene.toonShadowTint.a, 0.0, 1.0);
        float3 shadowTint = scene.toonShadowTint.rgb;
        float3 rimTint = float3(1.0, 0.96, 0.92);
        if (style >= 0.5 && style < 1.5) {
            rimTint = float3(1.0, 0.88, 0.78);
        } else if (style >= 1.5 && style < 2.5) {
            rimTint = float3(0.55, 0.78, 1.0);
        } else if (style >= 2.5) {
            rimTint = float3(1.0, 0.72, 0.36);
        }

        // A lifted two-tone ramp: the dark side keeps texture detail and
        // enough base color, instead of multiplying skin into a gray patch.
        float3 shadowColor = base.rgb * mix(float3(1.0), shadowTint, tintStrength)
                           * (0.40 + shadowLift * 0.42);
        float3 lightColor = base.rgb * (0.94 + 0.10 * bandValue);
        color = mix(shadowColor, lightColor, bandValue);
        // Ambient/fill barely shape the toon ramp, but they prevent crushed
        // blacks in clothing and hair.
        color *= (0.90 + ambientStrength * 0.20);
        color += base.rgb * mat.ambient.rgb * 0.045;
        float rimMask = pow(1.0 - max(dot(N, V), 0.0), 2.4);
        color += base.rgb * rimTint * rimMask * rimAmount;
    }

    // Photo / camera grade. Kept after both the toon and realistic branches so
    // the same exposure and color controls affect every render mode.
    float styleSaturation = style < 0.5 ? 1.0 : (style < 1.5 ? 1.12 : (style < 2.5 ? 1.04 : 1.22));
    float saturation = clamp(scene.ambientColor.a * styleSaturation, 0.55, 1.75);
    float luma = dot(color, float3(0.299, 0.587, 0.114));
    color = mix(float3(luma), color, saturation);
    float contrast = clamp(scene.gradeParams.x, 0.70, 1.60);
    color = (color - 0.5) * contrast + 0.5;
    color += max(color - 0.68, 0.0) * clamp(scene.gradeParams.y, 0.0, 2.0) * 0.45;
    float2 screenUV = in.position.xy / max(scene.viewportSize.xy, float2(1.0, 1.0));
    float vignette = smoothstep(0.34, 0.86, length(screenUV - 0.5));
    color *= 1.0 - vignette * clamp(scene.gradeParams.z, 0.0, 1.4);
    color *= exposure;
    color = max(color, 0.0);

    float alpha = base.a;
    if (mat.renderMode >= 2) { alpha = 1.0; }
    if (alpha < mat.alphaTest) { discard_fragment(); }
    return float4(color, alpha);
}

// MARK: - Edge (inverted hull, front faces culled)

struct EdgeVertexOut {
    float4 position [[position]];
};

vertex EdgeVertexOut mmd_edge_vertex(uint vid [[vertex_id]],
                                     device const float3 *positions [[buffer(0)]],
                                     device const float3 *normals [[buffer(1)]],
                                     device const uint4 *boneIndices [[buffer(3)]],
                                     device const float4 *weights [[buffer(4)]],
                                     device const float *edgeScales [[buffer(5)]],
                                     constant SceneUniforms &scene [[buffer(6)]],
                                     constant MaterialUniforms &mat [[buffer(7)]],
                                     device const float4x4 *palette [[buffer(8)]]) {
    uint4 bi = boneIndices[vid];
    float4 w = weights[vid];
    float4 skinned = w.x * (palette[bi.x] * float4(positions[vid], 1.0))
                   + w.y * (palette[bi.y] * float4(positions[vid], 1.0))
                   + w.z * (palette[bi.z] * float4(positions[vid], 1.0))
                   + w.w * (palette[bi.w] * float4(positions[vid], 1.0));
    float3 skinnedNormal = normalize(w.x * (palette[bi.x] * float4(normals[vid], 0.0)).xyz
                         + w.y * (palette[bi.y] * float4(normals[vid], 0.0)).xyz
                         + w.z * (palette[bi.z] * float4(normals[vid], 0.0)).xyz
                         + w.w * (palette[bi.w] * float4(normals[vid], 0.0)).xyz);

    float width = mat.edgeSize * max(edgeScales[vid], 0.0) * 0.025 * scene.params.z;
    float3 pushed = skinned.xyz + skinnedNormal * width;
    EdgeVertexOut out;
    out.position = scene.viewProjection * (scene.model * float4(pushed, 1.0));
    return out;
}

fragment float4 mmd_edge_fragment(constant MaterialUniforms &mat [[buffer(0)]]) {
    return float4(mat.edgeColor.rgb, 1.0);
}

// MARK: - Ground shadow

struct ShadowOut {
    float4 position [[position]];
};

vertex ShadowOut mmd_shadow_vertex(uint vid [[vertex_id]],
                                       device const float3 *positions [[buffer(0)]],
                                       device const uint4 *boneIndices [[buffer(3)]],
                                       device const float4 *weights [[buffer(4)]],
                                       constant SceneUniforms &scene [[buffer(6)]],
                                       device const float4x4 *palette [[buffer(7)]]) {
    uint4 bi = boneIndices[vid];
    float4 w = weights[vid];
    float4 skinned = w.x * (palette[bi.x] * float4(positions[vid], 1.0))
                   + w.y * (palette[bi.y] * float4(positions[vid], 1.0))
                   + w.z * (palette[bi.z] * float4(positions[vid], 1.0))
                   + w.w * (palette[bi.w] * float4(positions[vid], 1.0));
    float4 world = scene.model * float4(skinned.xyz, 1.0);
    world.y = scene.params.x;
    ShadowOut out;
    out.position = scene.viewProjection * world;
    return out;
}

fragment float4 mmd_shadow_fragment() {
    return float4(0.0, 0.0, 0.0, 0.55);
}

// MARK: - Grid

struct OverlayVertex {
    float3 position;
    float4 color;
};

struct OverlayOut {
    float4 position [[position]];
    float4 color;
    float3 worldPosition;
};

vertex OverlayOut mmd_grid_vertex(uint vid [[vertex_id]],
                                  device const OverlayVertex *vertices [[buffer(0)]],
                                  constant SceneUniforms &scene [[buffer(1)]]) {
    OverlayVertex v = vertices[vid];
    OverlayOut out;
    out.position = scene.viewProjection * float4(v.position, 1.0);
    out.color = v.color;
    out.worldPosition = v.position;
    return out;
}

fragment float4 mmd_grid_fragment(OverlayOut in [[stage_in]],
                                  constant SceneUniforms &scene [[buffer(0)]]) {
    float spacing = max(scene.params.y, 0.05);
    float2 coord = in.worldPosition.xz / spacing;
    float2 derivative = fwidth(coord);
    float2 grid = abs(fract(coord - 0.5) - 0.5) / max(derivative, float2(0.0001));
    float line = min(grid.x, grid.y);
    float alpha = (1.0 - min(line, 1.0)) * 0.45;

    float2 majorCoord = in.worldPosition.xz / (spacing * 10.0);
    float2 majorDerivative = fwidth(majorCoord);
    float2 majorGrid = abs(fract(majorCoord - 0.5) - 0.5) / max(majorDerivative, float2(0.0001));
    float majorLine = min(majorGrid.x, majorGrid.y);
    float majorAlpha = (1.0 - min(majorLine, 1.0)) * 0.55;

    float3 color = float3(0.42, 0.45, 0.5);
    color = mix(color, float3(0.6, 0.65, 0.7), float3(majorAlpha / 0.55));

    float distanceToCamera = distance(in.worldPosition, scene.cameraPosition.xyz);
    float fade = clamp(1.0 - distanceToCamera / (spacing * 90.0), 0.0, 1.0);
    alpha = max(alpha, majorAlpha) * fade;
    return float4(color, alpha);
}

// MARK: - Bone overlay

vertex OverlayOut mmd_overlay_vertex(uint vid [[vertex_id]],
                                     device const OverlayVertex *vertices [[buffer(0)]],
                                     constant SceneUniforms &scene [[buffer(1)]]) {
    OverlayVertex v = vertices[vid];
    OverlayOut out;
    out.position = scene.viewProjection * float4(v.position, 1.0);
    out.color = v.color;
    out.worldPosition = v.position;
    return out;
}

fragment float4 mmd_overlay_fragment(OverlayOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Studio backdrop

struct BackdropUniforms {
    float4 topColor;
    float4 bottomColor;
    float4 glowColor;
    float4 params;          // x: glow strength, y: vignette
};

struct BackdropOut {
    float4 position [[position]];
    float2 uv;
};

vertex BackdropOut mmd_backdrop_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(-1.0, -1.0);
    if (vid == 1) { p = float2(3.0, -1.0); }
    if (vid == 2) { p = float2(-1.0, 3.0); }
    BackdropOut out;
    // Push the backdrop to the far plane; depth compare is lessEqual and the
    // depth buffer was cleared to 1.0, so it still covers the clear color but
    // can never occlude the character.
    out.position = float4(p, 1.0, 1.0);
    out.uv = p * 0.5 + 0.5;
    return out;
}

fragment float4 mmd_backdrop_fragment(BackdropOut in [[stage_in]],
                                      constant BackdropUniforms &bg [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 color = mix(bg.bottomColor.rgb, bg.topColor.rgb,
                       smoothstep(0.0, 1.0, uv.y));
    float2 centered = uv - 0.5;
    centered.x *= 1.25;
    float glow = exp(-dot(centered, centered) * 5.2);
    color += bg.glowColor.rgb * glow * clamp(bg.params.x, 0.0, 1.0) * 0.22;
    float vignette = smoothstep(0.34, 0.88, length(centered));
    color *= 1.0 - vignette * clamp(bg.params.y, 0.0, 1.0) * 0.62;
    return float4(max(color, 0.0), 1.0);
}

// Optional imported backdrop image. Fills the frame with aspect-fill and
// keeps the same far-plane depth as the gradient backdrop.
fragment float4 mmd_backdrop_image_fragment(BackdropOut in [[stage_in]],
                                            texture2d<float> image [[texture(0)]],
                                            constant float4 &params [[buffer(0)]]) {
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float imageAspect = max(0.0001, params.x);
    float viewAspect = max(0.0001, params.y);
    float2 scale = (imageAspect > viewAspect)
        ? float2(viewAspect / imageAspect, 1.0)
        : float2(1.0, imageAspect / viewAspect);
    uv = (uv - 0.5) * scale + 0.5;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = image.sample(s, uv);
    return float4(color.rgb, 1.0);
}

// MARK: - Contact shadow

struct ContactShadowOut {
    float4 position [[position]];
    float2 uv;
};

vertex ContactShadowOut mmd_contact_shadow_vertex(
    uint vid [[vertex_id]],
    device const OverlayVertex *vertices [[buffer(0)]],
    constant SceneUniforms &scene [[buffer(1)]]) {
    OverlayVertex v = vertices[vid];
    ContactShadowOut out;
    out.position = scene.viewProjection * float4(v.position, 1.0);
    out.uv = v.color.xy;
    return out;
}

fragment float4 mmd_contact_shadow_fragment(ContactShadowOut in [[stage_in]]) {
    float2 p = (in.uv - 0.5) * 2.0;
    float d2 = dot(p, p);
    float alpha = exp(-d2 * 3.4) * 0.30;
    alpha *= smoothstep(0.0, 0.34, 1.0 - length(p));
    return float4(0.006, 0.008, 0.012, alpha);
}
