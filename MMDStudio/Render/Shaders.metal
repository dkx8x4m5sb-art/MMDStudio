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
    // x: outline width in pixels, y: specular strength, z: skin scatter,
    // w: shadow hue shift.
    float4 renderParams;
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
    // x: specular strength multiplier, y: metalness, z: skin flag,
    // w: outline width multiplier.
    float4 toonControl;
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
    float3 viewPosition;
};

/// Skinning helpers. Shared by the body pass and the outline pass so both see
/// exactly the same deformed surface.
static inline float4 mmdSkinPosition(uint vid,
                                     float3 position,
                                     device const uint4 *boneIndices,
                                     device const float4 *weights,
                                     device const float4x4 *palette,
                                     device const float4 *sdef,
                                     float sdefEnabled) {
    uint4 bi = boneIndices[vid];
    float4 w = weights[vid];
    float4 center = sdef[vid * 3 + 0];
    // SDEF is opt-in. The sphere solve is only correct when the converter
    // wrote C/R0/R1 in model space; several popular exporters write bone-local
    // or zero values, and using them tears skirts and cuffs apart.
    if (center.w > 0.5 && sdefEnabled > 0.5) {
        // SDEF: the vertex rides a sphere whose centre follows both bones.
        // Treating these as plain BDEF2 (the old behaviour) collapsed skirts
        // and cuffs into the body while the legs moved.
        float4 r0 = sdef[vid * 3 + 1];
        float4 r1 = sdef[vid * 3 + 2];
        // SDEF deforms the vertex on a sphere centred at C. The previous
        // version transformed `v - C` with a matrix that still carries the
        // bone translation, so at rest the whole patch slid by -C (tens of
        // centimetres) and skirts, cuffs and chest caved into the body.
        //
        // Weight the sphere's centre and a pure rotation, then rotate the
        // offset. At rest (all palettes identity) this reduces to exactly v.
        float4x4 m0 = palette[bi.x];
        float4x4 m1 = palette[bi.y];
        float3 center0 = (m0 * float4(center.xyz + r0.xyz, 1.0)).xyz;
        float3 center1 = (m1 * float4(center.xyz + r1.xyz, 1.0)).xyz;
        float3 sphereCenter = w.x * center0 + w.y * center1;
        // Metal has no float4x4 -> float3x3 cast; take the upper-left 3x3 by
        // columns so the translation stays behind.
        float3x3 rot0 = float3x3(m0[0].xyz, m0[1].xyz, m0[2].xyz);
        float3x3 rot1 = float3x3(m1[0].xyz, m1[1].xyz, m1[2].xyz);
        float3x3 rotation = w.x * rot0 + w.y * rot1;
        float3 offset = position - center.xyz - (w.x * r0.xyz + w.y * r1.xyz);
        return float4(sphereCenter + rotation * offset, 1.0);
    }
    return w.x * (palette[bi.x] * float4(position, 1.0))
         + w.y * (palette[bi.y] * float4(position, 1.0))
         + w.z * (palette[bi.z] * float4(position, 1.0))
         + w.w * (palette[bi.w] * float4(position, 1.0));
}

static inline float3 mmdSkinNormal(uint vid,
                                   float3 normal,
                                   device const uint4 *boneIndices,
                                   device const float4 *weights,
                                   device const float4x4 *palette,
                                   device const float4 *sdef,
                                   float sdefEnabled) {
    uint4 bi = boneIndices[vid];
    float4 w = weights[vid];
    float4 center = sdef[vid * 3 + 0];
    if (center.w > 0.5 && sdefEnabled > 0.5) {
        float3 n0 = (palette[bi.x] * float4(normal, 0.0)).xyz;
        float3 n1 = (palette[bi.y] * float4(normal, 0.0)).xyz;
        return w.x * n0 + w.y * n1;
    }
    return w.x * (palette[bi.x] * float4(normal, 0.0)).xyz
         + w.y * (palette[bi.y] * float4(normal, 0.0)).xyz
         + w.z * (palette[bi.z] * float4(normal, 0.0)).xyz
         + w.w * (palette[bi.w] * float4(normal, 0.0)).xyz;
}

// MARK: - Mesh

vertex MeshVertexOut mmd_mesh_vertex(uint vid [[vertex_id]],
                                     device const float3 *positions [[buffer(0)]],
                                     device const float3 *normals [[buffer(1)]],
                                     device const float2 *uvs [[buffer(2)]],
                                     device const uint4 *boneIndices [[buffer(3)]],
                                     device const float4 *weights [[buffer(4)]],
                                     device const float *edgeScales [[buffer(5)]],
                                     constant SceneUniforms &scene [[buffer(6)]],
                                     device const float4x4 *palette [[buffer(7)]],
                                     device const float4 *sdef [[buffer(8)]]) {
    float3 skinned = mmdSkinPosition(vid, positions[vid], boneIndices, weights, palette, sdef, scene.renderParams.w).xyz;
    float3 skinnedNormal = mmdSkinNormal(vid, normals[vid], boneIndices, weights, palette, sdef, scene.renderParams.w);

    float4 world = scene.model * float4(skinned, 1.0);
    float3 worldNormal = normalize((scene.normalMatrix * float4(skinnedNormal, 0.0)).xyz);
    float4 view = scene.view * world;

    MeshVertexOut out;
    out.position = scene.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = worldNormal;
    out.viewNormal = normalize((scene.view * float4(worldNormal, 0.0)).xyz);
    out.uv = uvs[vid];
    out.edgeScale = edgeScales[vid];
    out.viewPosition = view.xyz;
    return out;
}

/// Cel ramp with antialiased steps. `fwidth` keeps the terminator one pixel
/// wide at any resolution, which is what stops a two-tone shader from looking
/// like a jagged stencil on hair and fingers.
static inline float mmdToonRamp(float value, float steps, float softness) {
    float scaled = clamp(value, 0.0, 1.0) * steps;
    float level = floor(scaled);
    float fraction = scaled - level;
    float aa = max(fwidth(scaled) * 1.2, max(softness * 0.5, 0.001));
    float blend = smoothstep(0.5 - aa, 0.5 + aa, fraction);
    return clamp((level + blend) / max(steps, 1.0), 0.0, 1.0);
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

    // Sphere maps are authored per material and stay in every mode.
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
    float3 keyLightColor = scene.lightColor.rgb;

    // Evaluate up to eight user lights. The toon modes keep a single key
    // light (the first sun) for the ramp and use the rest as ambient/fill, so
    // a fill light never creates a second hard terminator.
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
        if (toonOnly && type != 0) {
            ambientLight += light.color.rgb * light.params.y * 0.18;
            continue;
        }
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
                mainNdl = clamp(dot(N, toLight), -1.0, 1.0);
                keyLightColor = light.color.rgb * light.params.y;
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

    if (lightCount == 0 || (toonOnly && !mainSunSet)) {
        float3 L = normalize(scene.lightDirection.xyz);
        mainNdl = clamp(dot(N, L), -1.0, 1.0);
        directLight = scene.lightColor.rgb * max(mainNdl, 0.0);
        keyLightColor = scene.lightColor.rgb;
        ambientLight = scene.ambientColor.rgb * ambientStrength;
    }

    float3 L = normalize(scene.lightDirection.xyz);
    float3 color = base.rgb;

    if (mat.renderMode == 2) {
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
        float3 fillDirection = normalize(float3(-L.x, 0.30, -L.z));
        float fill = max(dot(N, fillDirection), 0.0) * clamp(scene.lightParams.y, 0.0, 1.0);
        float rim = pow(1.0 - max(dot(N, V), 0.0), 2.0) * clamp(scene.lightParams.z, 0.0, 1.0);
        color = base.rgb * (ambientLight * 0.72 + directLight * 0.85
                            + scene.lightColor.rgb * fill * 0.18
                            + scene.lightColor.rgb * rim * 0.30);
        color += mat.specular.rgb * pow(max(dot(N, normalize(L + V)), 0.0),
                                        max(mat.specular.w, 1.0)) * 0.35 + specularSum;
    } else {
        // MARK: Cel shading (Genshin-style)
        //
        // The reference shader (GenshinCelShaderURP) builds its look from a
        // small number of hard decisions rather than from a physically based
        // light integral: one quantized key-light ramp, a hue-shifted shadow
        // that keeps saturation, a ladder highlight, a rim term that only
        // appears on the lit side, and an inverted-hull outline. This is that
        // structure, driven by the PMX material data we actually have.
        float steps = max(2.0, scene.lightCount.w);
        float softness = clamp(scene.toonParams.x, 0.0, 0.45);
        float lift = clamp(scene.toonParams.y, 0.0, 1.0);
        float rimAmount = clamp(scene.toonParams.z, 0.0, 1.0);
        float tintStrength = clamp(scene.toonShadowTint.a, 0.0, 1.0);
        float3 shadowTint = scene.toonShadowTint.rgb;
        float metalness = clamp(mat.toonControl.y, 0.0, 1.0);
        float isSkin = clamp(mat.toonControl.z, 0.0, 1.0);
        float specScale = clamp(scene.renderParams.y, 0.0, 2.0) * max(mat.toonControl.x, 0.0);

        float litRaw = mainNdl * 0.5 + 0.5;
        float ramp = mmdToonRamp(litRaw, steps, softness);
        // Authored toon ramps still carry the model's intent; blend them in
        // without letting them flatten the style presets.
        if ((mat.flags & kFlagHasToon) != 0) {
            float authored = clamp(toonMap.sample(clampSampler, float2(litRaw, 0.5)).r
                                   * mat.toonTint.r, 0.0, 1.0);
            ramp = mix(ramp, authored, 0.30);
        }
        // Metal reads as "always somewhat lit" on its highlight side.
        ramp = mix(ramp, max(ramp, 0.55), metalness * 0.5);

        // Shadow keeps the albedo hue instead of turning grey: multiply by a
        // tinted factor, then lift the floor so cloth does not crush.
        // `mix(0.42, 0.80, lift)` kept the shadow at ~95% of the albedo at the
        // default lift, which read as a grey wash instead of a cel shadow.
        float3 shadowColor = base.rgb * mix(float3(1.0), shadowTint, tintStrength)
                           * (0.35 + 0.60 * lift);
        float3 litColor = base.rgb * (0.97 + 0.06 * ramp);
        // Shadow term is tinted by the key light so a warm sun and a cold fill
        // produce different shadow temperatures.
        litColor *= mix(float3(1.0), keyLightColor, 0.35);

        color = mix(shadowColor, litColor, ramp);
        color += base.rgb * ambientLight * 0.30;

        // Ladder highlight. A hard specular step is the single strongest
        // "anime" cue after the ramp; MMD materials already carry the colour
        // and power so it needs no extra authoring.
        float3 H = normalize(L + V);
        float specPower = max(mat.specular.w, 1.0);
        float spec = pow(max(dot(N, H), 0.0), specPower);
        float specAA = max(fwidth(spec) * 1.4, 0.02);
        float specMask = smoothstep(0.35 - specAA, 0.45 + specAA, spec);
        float specFacing = smoothstep(-0.1, 0.35, ramp);
        color += mat.specular.rgb * keyLightColor * specMask * specScale
               * (0.35 + 0.65 * specFacing) * (1.0 + metalness);

        // Rim light on the lit silhouette. Genshin keeps it off the shadow
        // side, which is what makes it read as a contour instead of a fog.
        float fresnel = 1.0 - saturate(dot(N, V));
        float rim = smoothstep(0.55, 0.98, fresnel);
        rim *= saturate(ramp * 1.6 - 0.15);
        float3 rimTint = float3(1.0, 0.97, 0.94);
        if (scene.params.w >= 0.5 && scene.params.w < 1.5) {
            rimTint = float3(1.0, 0.90, 0.80);
        } else if (scene.params.w >= 1.5 && scene.params.w < 2.5) {
            rimTint = float3(0.62, 0.82, 1.0);
        } else if (scene.params.w >= 2.5) {
            rimTint = float3(1.0, 0.74, 0.40);
        }
        color += rimTint * rim * rimAmount * 0.85;

        // Skin and thin cloth bleed warm light through the terminator.
        float scatter = isSkin * clamp(scene.renderParams.z, 0.0, 1.0);
        if (scatter > 0.001) {
            float bleed = (1.0 - ramp) * smoothstep(0.05, 0.75, litRaw) * (0.35 + 0.65 * fresnel);
            color += base.rgb * float3(1.0, 0.52, 0.42) * bleed * scatter * 0.55;
        }
    }

    // Photo / camera grade, applied to every mode.
    float style = scene.params.w;
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

// MARK: - Edge (inverted hull, front faces culled, constant pixel width)

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
                                     device const float4x4 *palette [[buffer(8)]],
                                     device const float4 *sdef [[buffer(9)]]) {
    float3 skinned = mmdSkinPosition(vid, positions[vid], boneIndices, weights, palette, sdef, scene.renderParams.w).xyz;
    float3 skinnedNormal = normalize(mmdSkinNormal(vid, normals[vid], boneIndices, weights, palette, sdef, scene.renderParams.w));

    float4 world = scene.model * float4(skinned, 1.0);
    float4 clip = scene.viewProjection * world;
    float3 viewNormal = normalize((scene.view * float4(skinnedNormal, 0.0)).xyz);

    // Push the hull out in screen space so the line weight stays identical
    // whether the camera is 3 units or 30 units away.
    float2 direction = viewNormal.xy;
    float magnitude = length(direction);
    direction = magnitude > 0.0001 ? direction / magnitude : float2(0.0, 1.0);
    // Width is specified against a 1080p frame so the line keeps the same
    // relative weight on a phone and on a 4K export.
    float resolutionScale = max(0.5, scene.viewportSize.y / 1080.0);
    float pixels = max(0.4, scene.renderParams.x * resolutionScale)
                 * clamp(mat.edgeSize, 0.25, 4.0)
                 * clamp(edgeScales[vid], 0.15, 4.0)
                 * clamp(scene.params.z, 0.0, 4.0);
    float2 viewport = max(scene.viewportSize.xy, float2(1.0, 1.0));
    clip.xy += direction * (pixels * 2.0 / viewport) * clip.w;

    EdgeVertexOut out;
    out.position = clip;
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
    // 纹理上传时已经翻过行（decodeCGImage 里做的那次 translate/scale），
    // 内存第 0 行是图像的**底边**，与 GL/MMD 的 v=0 一致。这里再翻一次
    // 等于把照片上下颠倒 —— 导入的背景图整幅倒过来就是这个原因。
    float2 uv = in.uv;
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
