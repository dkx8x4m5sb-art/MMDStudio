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
    // x: 描边宽度（像素），y: 高光强度，z: 皮肤透光，
    // w: 阴影色相偏移。
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
    // x: 高光强度倍率，y: 金属度，z: 皮肤标记，
    // w: 描边宽度倍率。
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

/// 蒙皮辅助函数。主体与描边两个 pass 共用，
/// 保证两边看到的形变表面完全一致。
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
    // SDEF 是可选路径。只有转换器把 C/R0/R1 写在模型空间时，
    // 球面解算才正确；几个流行导出器写成骨骼局部值或零，
    // 用它们会把裙子和袖口撕开。
    if (center.w > 0.5 && sdefEnabled > 0.5) {
        // SDEF：顶点骑在一个随两根骨骼移动的球面上。
        // 把它们当普通 BDEF2 处理（旧行为）会让裙子和袖口
        // 在腿动的时候塌进身体。
        float4 r0 = sdef[vid * 3 + 1];
        float4 r1 = sdef[vid * 3 + 2];
        // SDEF 把顶点形变到以 C 为球心的球面上。上一版
        // 用仍带骨骼平移的矩阵去变换 `v - C`，
        // 静止时整片面片就平移了 -C（几十厘米），
        // 裙子、袖口和胸口全凹进身体里。
        //
        // 给球心加权、只取纯旋转，再旋转偏移量。
        // 静止时（所有 palette 为单位阵）正好还原成 v。
        float4x4 m0 = palette[bi.x];
        float4x4 m1 = palette[bi.y];
        float3 center0 = (m0 * float4(center.xyz + r0.xyz, 1.0)).xyz;
        float3 center1 = (m1 * float4(center.xyz + r1.xyz, 1.0)).xyz;
        float3 sphereCenter = w.x * center0 + w.y * center1;
        // Metal 没有 float4x4 → float3x3 的转换；按列取
        // 左上 3x3，把平移留在外面。
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

// MARK: - 网格

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

/// 带抗锯齿台阶的卡通 ramp。`fwidth` 让明暗交界
/// 在任何分辨率下都保持一像素宽，两色着色才不会
/// 在头发和手指上看起来像锯齿模板。
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

    // 球面贴图按材质编写，任何模式下都保留。
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

    // 最多求值八盏用户光源。卡通模式只让第一束主光
    // 参与 ramp，其余当环境/补光，补光因此
    // 不会造出第二个硬交界。
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
        // MARK: 卡通着色（原神风格）
        //
        // 参考着色器（GenshinCelShaderURP）的观感来自
        // 少量硬性判断，而不是物理光照积分：
        // 一条量化的主光 ramp、保留饱和度的色相偏移阴影、
        // 阶梯高光、只出现在受光侧的轮廓光，
        // 以及反向外壳描边。这里就是那套结构，
        // 由我们真正拥有的 PMX 材质数据驱动。
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
        // 作者写的 toon ramp 仍带着模型的原意；
        // 把它混进来，但不要让它抹平风格预设。
        if ((mat.flags & kFlagHasToon) != 0) {
            float authored = clamp(toonMap.sample(clampSampler, float2(litRaw, 0.5)).r
                                   * mat.toonTint.r, 0.0, 1.0);
            ramp = mix(ramp, authored, 0.30);
        }
        // 金属在受光侧读起来要「总有点亮」。
        ramp = mix(ramp, max(ramp, 0.55), metalness * 0.5);

        // 阴影保留 albedo 的色相而不是发灰：乘一个带色的
        // 系数，再把地板抬起来，布料才不会被压死。
        // `mix(0.42, 0.80, lift)` 在默认 lift 下把阴影留在
        // albedo 的 ~95%，看起来是一层灰浆而不是卡通阴影。
        float3 shadowColor = base.rgb * mix(float3(1.0), shadowTint, tintStrength)
                           * (0.35 + 0.60 * lift);
        float3 litColor = base.rgb * (0.97 + 0.06 * ramp);
        // 阴影项按主光染色，暖阳与冷补光
        // 因此产生不同的阴影色温。
        litColor *= mix(float3(1.0), keyLightColor, 0.35);

        color = mix(shadowColor, litColor, ramp);
        color += base.rgb * ambientLight * 0.30;

        // 阶梯高光。硬边高光是 ramp 之后最强的
        // 「动画感」信号；MMD 材质本来就带颜色和
        // 幂次，不需要额外作者设定。
        float3 H = normalize(L + V);
        float specPower = max(mat.specular.w, 1.0);
        float spec = pow(max(dot(N, H), 0.0), specPower);
        float specAA = max(fwidth(spec) * 1.4, 0.02);
        float specMask = smoothstep(0.35 - specAA, 0.45 + specAA, spec);
        float specFacing = smoothstep(-0.1, 0.35, ramp);
        color += mat.specular.rgb * keyLightColor * specMask * specScale
               * (0.35 + 0.65 * specFacing) * (1.0 + metalness);

        // 受光轮廓上的边缘光。原神在背光侧关掉它，
        // 这才让它读作轮廓线而不是一层雾。
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

        // 皮肤和薄布在交界处透出暖光。
        float scatter = isSkin * clamp(scene.renderParams.z, 0.0, 1.0);
        if (scatter > 0.001) {
            float bleed = (1.0 - ramp) * smoothstep(0.05, 0.75, litRaw) * (0.35 + 0.65 * fresnel);
            color += base.rgb * float3(1.0, 0.52, 0.42) * bleed * scatter * 0.55;
        }
    }

    // 照片/相机调色，所有模式都套用。
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

// MARK: - 描边（反向外壳，剔除正面，恒定像素宽）

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

    // 在屏幕空间把外壳推出去，线宽因此
    // 在相机 3 单位或 30 单位远时都一致。
    float2 direction = viewNormal.xy;
    float magnitude = length(direction);
    direction = magnitude > 0.0001 ? direction / magnitude : float2(0.0, 1.0);
    // 宽度按 1080p 画面标定，线条在手机和
    // 4K 导出上保持同样的相对粗细。
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

// MARK: - 地面阴影

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

// MARK: - 网格线

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

// MARK: - 骨骼叠加

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

// MARK: - 摄影棚背景

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
    // 把背景推到远平面；深度比较是 lessEqual，
    // 而且深度缓冲已清成 1.0，所以它仍然盖住清屏色，
    // 但永远不会遮挡角色。
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

// 可选的导入背景图。按 aspect-fill 铺满画面，
// 深度与渐变背景一样留在远平面。
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

// MARK: - 接触阴影

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
