#!/usr/bin/env python3
"""Generate a self-contained sample PMX 2.0 model and a VMD motion.

The model is a stylised humanoid assembled from flat-shaded primitives so the
renderer can be validated without shipping third-party assets.
"""
import math
import os
import struct
import zlib

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "TestAssets", "SampleModel")
os.makedirs(OUT_DIR, exist_ok=True)


def f32(x):
    return struct.pack("<f", float(x))


def u8(x):
    return struct.pack("<B", x)


def u16(x):
    return struct.pack("<H", x)


def u32(x):
    return struct.pack("<I", x)


def i32(x):
    return struct.pack("<i", int(x))


def vec3(v):
    return f32(v[0]) + f32(v[1]) + f32(v[2])


def vec4(v):
    return vec3(v[:3]) + f32(v[3])


def text_utf16(s):
    b = s.encode("utf-16-le")
    return i32(len(b)) + b


def text_sjis(s, length):
    b = s.encode("shift_jis")
    b = b[:length]
    return b + b"\0" * (length - len(b))


# ----------------------------------------------------------------------------
# Geometry builder

MATERIALS = [
    # name, diffuse, specular, power, ambient, flags, edge color, edge size, tex, toon, memo
    ("肌", "skin", (1.00, 0.84, 0.76, 1), (0.10, 0.10, 0.10), 4, (0.35, 0.25, 0.23), 0x1A, (0.35, 0.18, 0.12, 1), 0.55, -1, 1, ""),
    ("髪", "hair", (0.30, 0.88, 0.94, 1), (0.30, 0.40, 0.40), 8, (0.10, 0.28, 0.30), 0x1A, (0.05, 0.22, 0.26, 1), 0.8, -1, 3, ""),
    ("衣", "top", (0.96, 0.97, 1.00, 1), (0.25, 0.25, 0.28), 12, (0.28, 0.30, 0.36), 0x1A, (0.08, 0.10, 0.18, 1), 0.7, 0, 1, "条纹上衣"),
    ("裙", "skirt", (0.13, 0.17, 0.32, 1), (0.20, 0.20, 0.30), 16, (0.06, 0.07, 0.14), 0x1B, (0.02, 0.03, 0.08, 1), 0.9, -1, 2, ""),
    ("靴", "boots", (0.09, 0.09, 0.12, 1), (0.35, 0.35, 0.38), 24, (0.03, 0.03, 0.05), 0x1A, (0.01, 0.01, 0.02, 1), 0.7, -1, 4, ""),
    ("眼", "eye", (0.04, 0.30, 0.36, 1), (0.20, 0.30, 0.30), 10, (0.02, 0.08, 0.10), 0x02, (0.0, 0.0, 0.0, 1), 0.0, -1, 0, ""),
    ("口", "mouth", (0.82, 0.20, 0.28, 1), (0.10, 0.05, 0.05), 6, (0.20, 0.05, 0.08), 0x02, (0.0, 0.0, 0.0, 1), 0.0, -1, 0, ""),
]

BONES = [
    # name, english, position, parent
    ("root", "root", (0.0, 0.0, 0.0), -1),
    ("center", "center", (0.0, 2.8, 0.0), 0),
    ("upper2", "upper body", (0.0, 4.6, 0.0), 1),
    ("neck", "neck", (0.0, 6.5, 0.0), 2),
    ("head", "head", (0.0, 7.6, 0.0), 3),
    ("hair", "hair", (0.0, 8.0, 0.2), 4),
    ("hair_L", "hair L", (1.25, 7.6, 0.35), 4),
    ("hair_R", "hair R", (-1.25, 7.6, 0.35), 4),
    ("arm_L", "arm L", (1.02, 6.15, 0.0), 2),
    ("elbow_L", "elbow L", (1.52, 5.15, 0.10), 8),
    ("wrist_L", "wrist L", (1.62, 4.20, 0.18), 9),
    ("arm_R", "arm R", (-1.02, 6.15, 0.0), 2),
    ("elbow_R", "elbow R", (-1.52, 5.15, 0.10), 11),
    ("wrist_R", "wrist R", (-1.62, 4.20, 0.18), 12),
    ("leg_L", "leg L", (0.42, 3.25, 0.0), 1),
    ("knee_L", "knee L", (0.42, 1.85, 0.0), 14),
    ("ankle_L", "ankle L", (0.42, 0.45, 0.0), 15),
    ("foot_L", "foot L", (0.42, 0.20, -0.18), 16),
    ("leg_R", "leg R", (-0.42, 3.25, 0.0), 1),
    ("knee_R", "knee R", (-0.42, 1.85, 0.0), 18),
    ("ankle_R", "ankle R", (-0.42, 0.45, 0.0), 19),
    ("foot_R", "foot R", (-0.42, 0.20, -0.18), 20),
]

BONE_INDEX = {b[0]: i for i, b in enumerate(BONES)}
MAT_INDEX = {m[1]: i for i, m in enumerate(MATERIALS)}

vertices = []   # dict pos, normal, uv, bone
indices = []
material_counts = [0] * len(MATERIALS)
eye_indices = []
mouth_indices = []
REF = (0.0, 5.0, 0.0)


def add_tri(p0, p1, p2, mat, bone, normal=None, uv=((0, 0), (0, 0), (0, 0))):
    p0, p1, p2 = tuple(p0), tuple(p1), tuple(p2)
    bone = bone if isinstance(bone, int) else BONE_INDEX[bone]
    normals = []
    for p in (p0, p1, p2):
        normals.append(norm(sub(p, normal)) if normal is not None else norm(sub(p, REF)))
    base = len(vertices)
    for i, p in enumerate((p0, p1, p2)):
        vertices.append({"position": p, "normal": normals[i], "uv": uv[i], "bone": bone})
    indices.extend([base, base + 1, base + 2])
    material_counts[mat] += 3
    return base, base + 1, base + 2


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def norm(v):
    l = math.sqrt(sum(x * x for x in v)) or 1.0
    return (v[0] / l, v[1] / l, v[2] / l)


def add_quad(p0, p1, p2, p3, mat, bone, normal=None, uv=None):
    bone = bone if isinstance(bone, int) else BONE_INDEX[bone]
    ids = []
    if uv is None:
        uv = ((0, 0), (1, 0), (1, 1), (0, 1))
    base = len(vertices)
    for p, tex in zip((p0, p1, p2, p3), uv):
        n = norm(sub(p, normal)) if normal is not None else norm(sub(p, REF))
        vertices.append({"position": tuple(p), "normal": n, "uv": tex, "bone": bone})
    indices.extend([base, base + 1, base + 2, base, base + 2, base + 3])
    material_counts[mat] += 6
    ids.extend([base, base + 1, base + 2, base + 3])
    return ids


def add_sphere(center, radius, mat, bone, lat=10, lon=14, scale=(1, 1, 1)):
    global REF
    old_ref = REF
    REF = tuple(center)
    ids = []
    for i in range(lat):
        phi0 = math.pi * i / lat
        phi1 = math.pi * (i + 1) / lat
        for j in range(lon):
            t0 = 2 * math.pi * j / lon
            t1 = 2 * math.pi * (j + 1) / lon

            def pt(phi, theta):
                return (center[0] + radius * scale[0] * math.sin(phi) * math.cos(theta),
                        center[1] + radius * scale[1] * math.cos(phi),
                        center[2] + radius * scale[2] * math.sin(phi) * math.sin(theta))

            p00, p01, p10, p11 = pt(phi0, t0), pt(phi1, t0), pt(phi0, t1), pt(phi1, t1)
            if i == 0:
                ids += add_tri(p00, p01, p11, mat, bone, normal=tuple(center))
            elif i == lat - 1:
                ids += add_tri(p00, p01, p10, mat, bone, normal=tuple(center))
            else:
                ids += add_quad(p00, p01, p11, p10, mat, bone, normal=None)
    REF = old_ref
    return ids


def add_tube(p0, p1, r0, r1, mat, bone, sides=8, caps=True):
    global REF
    old_ref = REF
    p0, p1 = tuple(p0), tuple(p1)
    REF = ((p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5, (p0[2] + p1[2]) * 0.5)
    axis = norm(sub(p1, p0))
    # Pick a stable perpendicular basis.
    ref = (0, 1, 0) if abs(axis[1]) < 0.9 else (1, 0, 0)
    u = norm(cross(axis, ref))
    v = norm(cross(axis, u))
    ids = []
    rings = []
    for k, (p, r) in enumerate(((p0, r0), (p1, r1))):
        ring = []
        for j in range(sides):
            t = 2 * math.pi * j / sides
            ring.append((p[0] + (u[0] * math.cos(t) + v[0] * math.sin(t)) * r,
                         p[1] + (u[1] * math.cos(t) + v[1] * math.sin(t)) * r,
                         p[2] + (u[2] * math.cos(t) + v[2] * math.sin(t)) * r))
        rings.append(ring)
    for j in range(sides):
        j2 = (j + 1) % sides
        a, b, c, d = rings[0][j], rings[1][j], rings[1][j2], rings[0][j2]
        ids += add_quad(a, b, c, d, mat, bone)
    if caps:
        for ring, sign in ((rings[0], -1), (rings[1], 1)):
            for j in range(1, sides - 1):
                ids += list(add_tri(ring[0], ring[j], ring[j + 1], mat, bone))
    REF = old_ref
    return ids


def add_box(center, size, mat, bone):
    global REF
    old_ref = REF
    REF = tuple(center)
    cx, cy, cz = center
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    corners = {
        "000": (cx - hx, cy - hy, cz - hz), "100": (cx + hx, cy - hy, cz - hz),
        "110": (cx + hx, cy + hy, cz - hz), "010": (cx - hx, cy + hy, cz - hz),
        "001": (cx - hx, cy - hy, cz + hz), "101": (cx + hx, cy - hy, cz + hz),
        "111": (cx + hx, cy + hy, cz + hz), "011": (cx - hx, cy + hy, cz + hz),
    }
    faces = [
        ("001", "101", "111", "011"), ("000", "010", "110", "100"),
        ("000", "001", "011", "010"), ("100", "110", "111", "101"),
        ("000", "100", "101", "001"), ("010", "011", "111", "110"),
    ]
    ids = []
    for face in faces:
        ids += add_quad(*[corners[k] for k in face], mat, bone)
    REF = old_ref
    return ids


# --- Body -------------------------------------------------------------------

REF = (0.0, 5.4, 0.0)
# torso as a tapered octagonal body
for i in range(10):
    y0 = 4.45 + (6.35 - 4.45) * i / 10
    y1 = 4.45 + (6.35 - 4.45) * (i + 1) / 10
    r0 = 0.93 - 0.12 * (i / 10)
    r1 = 0.93 - 0.12 * ((i + 1) / 10)
    ring0 = []
    ring1 = []
    for j in range(10):
        t = 2 * math.pi * j / 10
        ring0.append((r0 * math.cos(t), y0, r0 * 0.62 * math.sin(t)))
        ring1.append((r1 * math.cos(t), y1, r1 * 0.62 * math.sin(t)))
    for j in range(10):
        j2 = (j + 1) % 10
        add_quad(ring0[j], ring1[j], ring1[j2], ring0[j2], MAT_INDEX["top"], BONE_INDEX["upper2"])
add_sphere((0, 6.35, 0), 0.83, MAT_INDEX["top"], BONE_INDEX["upper2"], lat=8, lon=12, scale=(1.0, 0.38, 0.62))

# neck
add_tube((0, 6.45, 0), (0, 7.05, 0), 0.24, 0.22, MAT_INDEX["skin"], BONE_INDEX["neck"])

# head
REF = (0.0, 7.62, 0.0)
add_sphere((0, 7.62, -0.02), 1.18, MAT_INDEX["skin"], BONE_INDEX["head"], lat=14, lon=18, scale=(1.0, 1.05, 0.98))

# eyes (slightly flattened, on the -Z front side)
for side in (-1, 1):
    ids = add_sphere((0.42 * side, 7.80, -1.10), 0.25, MAT_INDEX["eye"], BONE_INDEX["head"],
                     lat=7, lon=9, scale=(0.86, 1.05, 0.28))
    eye_indices += ids

# mouth
mouth_indices += add_box((0, 7.22, -1.12), (0.36, 0.075, 0.05), MAT_INDEX["mouth"], BONE_INDEX["head"])

# hair cap (top hemisphere, plus back curtain)
for i in range(7):
    phi0 = math.pi * 0.02 + (math.pi * 0.46) * i / 7
    phi1 = math.pi * 0.02 + (math.pi * 0.46) * (i + 1) / 7
    r = 1.27
    for j in range(18):
        t0 = 2 * math.pi * j / 18
        t1 = 2 * math.pi * (j + 1) / 18

        def hp(phi, theta):
            return (1.27 * math.sin(phi) * math.cos(theta),
                    7.62 + 1.28 * math.cos(phi),
                    -0.02 + 1.25 * math.sin(phi) * math.sin(theta))

        p00, p01, p10, p11 = hp(phi0, t0), hp(phi1, t0), hp(phi0, t1), hp(phi1, t1)
        add_quad(p00, p01, p11, p10, MAT_INDEX["hair"], BONE_INDEX["head"])

# back hair curtain
for i in range(5):
    y0 = 7.3 - i * 0.45
    y1 = 7.3 - (i + 1) * 0.45
    r0 = 1.30 - i * 0.06
    r1 = 1.30 - (i + 1) * 0.06
    for j in range(10):
        t0 = math.pi * 0.15 + math.pi * 0.7 * j / 10
        t1 = math.pi * 0.15 + math.pi * 0.7 * (j + 1) / 10
        p00 = (r0 * math.cos(t0), y0, 0.12 + r0 * math.sin(t0))
        p01 = (r1 * math.cos(t0), y1, 0.12 + r1 * math.sin(t0))
        p10 = (r0 * math.cos(t1), y0, 0.12 + r0 * math.sin(t1))
        p11 = (r1 * math.cos(t1), y1, 0.12 + r1 * math.sin(t1))
        add_quad(p00, p01, p11, p10, MAT_INDEX["hair"], BONE_INDEX["head"])

# bangs
for k in range(7):
    x = -0.9 + 1.8 * k / 6
    add_tube((x * 1.02, 8.78, -0.60), (x * 1.18, 7.92, -1.02),
             0.20, 0.05, MAT_INDEX["hair"], BONE_INDEX["head"], sides=5, caps=False)

# twin tails
for side in (-1, 1):
    bone = BONE_INDEX["hair_L" if side > 0 else "hair_R"]
    p0 = (1.20 * side, 8.05, 0.30)
    p1 = (1.55 * side, 6.20, 0.52)
    add_tube(p0, p1, 0.36, 0.22, MAT_INDEX["hair"], bone, sides=8, caps=True)
    add_tube(p1, (1.75 * side, 4.55, 0.62), 0.22, 0.08, MAT_INDEX["hair"], bone, sides=7, caps=True)

# skirt
REF = (0.0, 3.8, 0.0)
for i in range(8):
    y0 = 3.05 + (4.55 - 3.05) * i / 8
    y1 = 3.05 + (4.55 - 3.05) * (i + 1) / 8
    r0 = 1.46 - (1.46 - 0.88) * (i / 8)
    r1 = 1.46 - (1.46 - 0.88) * ((i + 1) / 8)
    for j in range(16):
        t0 = 2 * math.pi * j / 16
        t1 = 2 * math.pi * (j + 1) / 16
        p00 = (r0 * math.cos(t0), y0, r0 * 0.72 * math.sin(t0))
        p01 = (r1 * math.cos(t0), y1, r1 * 0.72 * math.sin(t0))
        p10 = (r0 * math.cos(t1), y0, r0 * 0.72 * math.sin(t1))
        p11 = (r1 * math.cos(t1), y1, r1 * 0.72 * math.sin(t1))
        add_quad(p00, p01, p11, p10, MAT_INDEX["skirt"], BONE_INDEX["center"])

# arms
for side in (-1, 1):
    s = "L" if side > 0 else "R"
    shoulder = (1.02 * side, 6.15, 0.0)
    elbow = (1.52 * side, 5.15, 0.10)
    wrist = (1.62 * side, 4.20, 0.18)
    add_tube(shoulder, elbow, 0.24, 0.18, MAT_INDEX["top"], BONE_INDEX["arm_" + s], sides=7)
    add_tube(elbow, wrist, 0.18, 0.12, MAT_INDEX["skin"], BONE_INDEX["elbow_" + s], sides=7)
    add_sphere(wrist, 0.18, MAT_INDEX["skin"], BONE_INDEX["wrist_" + s], lat=6, lon=8)

# legs
for side in (-1, 1):
    s = "L" if side > 0 else "R"
    hip = (0.42 * side, 3.25, 0.0)
    knee = (0.42 * side, 1.85, 0.0)
    ankle = (0.42 * side, 0.45, 0.0)
    add_tube(hip, knee, 0.30, 0.22, MAT_INDEX["skin"], BONE_INDEX["leg_" + s], sides=7)
    add_tube(knee, ankle, 0.24, 0.18, MAT_INDEX["boots"], BONE_INDEX["knee_" + s], sides=7)
    add_box((0.42 * side, 0.16, -0.20), (0.40, 0.28, 0.66), MAT_INDEX["boots"], BONE_INDEX["foot_" + s])

# ----------------------------------------------------------------------------
# Morph: smile (eyes lift / mouth corners spread)

MORPHS = []
smile_offsets = []
for idx in eye_indices:
    p = vertices[idx]["position"]
    sign = 1 if p[0] >= 0 else -1
    smile_offsets.append((idx, (0.06 * sign, 0.045, 0.0)))
for idx in mouth_indices:
    p = vertices[idx]["position"]
    sign = 1 if p[0] > 0.03 else (-1 if p[0] < -0.03 else 0)
    smile_offsets.append((idx, (0.16 * sign, 0.025, 0.0)))
MORPHS.append(("smile", "smile", 4, 1, smile_offsets))


# ----------------------------------------------------------------------------
# PNG texture for the top

def make_top_texture(path):
    w = h = 64
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            # soft diagonal cyan stripe pattern
            stripe = ((x + y) // 10) % 2
            if stripe:
                c = (90, 220, 235, 255)
            else:
                c = (250, 252, 255, 255)
            if y > 56:
                c = (20, 40, 70, 255)
            row.extend(c)
        rows.append(row)
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(t, data):
        return struct.pack(">I", len(data)) + t + data + struct.pack(">I", zlib.crc32(t + data) & 0xffffffff)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


make_top_texture(os.path.join(OUT_DIR, "top.png"))

# ----------------------------------------------------------------------------
# Serialize PMX

out = bytearray()
out += b"PMX "
out += f32(2.0)
out += u8(8)
out += bytes([0, 0, 4, 4, 4, 4, 4, 4])
out += text_utf16("MMD Studio Sample")
out += text_utf16("MMD Studio Sample")
out += text_utf16("Generated sample model for MMD Studio")
out += text_utf16("Generated sample model")

# vertices
out += i32(len(vertices))
for v in vertices:
    p = v["position"]
    n = v["normal"]
    # Mirror Z into the right-handed renderer convention at load time, but PMX is authored left-handed.
    out += vec3(p)
    out += vec3(n)
    out += f32(v["uv"][0]) + f32(v["uv"][1])
    out += u8(0)                      # BDEF1
    out += i32(v["bone"])
    out += f32(1.0)

# indices
out += i32(len(indices))
for i in indices:
    out += u32(i)

# textures
out += i32(1)
out += text_utf16("top.png")

# materials
out += i32(len(MATERIALS))
offset = 0
for idx, m in enumerate(MATERIALS):
    jp, en, diffuse, specular, power, ambient, flags, edge_color, edge_size, tex, toon, memo = m
    out += text_utf16(jp)
    out += text_utf16(en)
    out += vec4(diffuse)
    out += vec3(specular)
    out += f32(power)
    out += vec3(ambient)
    out += u8(flags)
    out += vec4(edge_color)
    out += f32(edge_size)
    out += i32(tex)
    out += i32(-1)                    # sphere
    out += u8(0)                     # sphere mode
    out += u8(1)                     # built-in toon
    out += u8(toon)
    out += text_utf16(memo)
    out += i32(material_counts[idx])
    offset += material_counts[idx]

# bones
out += i32(len(BONES))
for name, en, pos, parent in BONES:
    out += text_utf16(name)
    out += text_utf16(en)
    out += vec3(pos)
    out += i32(parent)
    out += i32(0)                    # layer
    flags = 0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0010
    out += u16(flags)
    out += i32(-1)                   # tail bone index

# morphs
out += i32(len(MORPHS))
for name, en, panel, typ, offsets in MORPHS:
    out += text_utf16(name)
    out += text_utf16(en)
    out += u8(panel)
    out += u8(typ)
    out += i32(len(offsets))
    for idx, off in offsets:
        out += u32(idx)
        out += vec3(off)

# no display frames, rigid bodies or constraints in the sample
out += i32(0)
out += i32(0)
out += i32(0)

with open(os.path.join(OUT_DIR, "sample.pmx"), "wb") as f:
    f.write(out)

print("PMX written", len(out), "bytes,", len(vertices), "vertices,", len(set(indices)), "indexed vertices,",
      len(indices) // 3, "triangles")

# ----------------------------------------------------------------------------
# VMD

def quat_axis(axis, degrees):
    a = math.radians(degrees) / 2
    s = math.sin(a)
    if axis == "x":
        return (s, 0.0, 0.0, math.cos(a))
    if axis == "y":
        return (0.0, s, 0.0, math.cos(a))
    return (0.0, 0.0, s, math.cos(a))


def default_bone_interp():
    b = bytearray(64)
    # channel (x1,y1,x2,y2) byte positions from the VMD spec
    for x1, y1, x2, y2 in ((0, 4, 8, 12), (1, 5, 9, 13), (17, 6, 10, 14), (18, 7, 11, 15)):
        b[x1] = 20
        b[y1] = 20
        b[x2] = 107
        b[y2] = 107
    return bytes(b)


def default_camera_interp():
    b = bytearray(24)
    for ch in range(6):
        b[ch * 4 + 0] = 20
        b[ch * 4 + 1] = 107
        b[ch * 4 + 2] = 20
        b[ch * 4 + 3] = 107
    return bytes(b)


bone_frames = []


def bone_key(name, frame, pos=(0, 0, 0), rot=(0, 0, 0, 1)):
    bone_frames.append((name, frame, pos, rot))


# A friendly wave, symmetric arm raise, head nod and slight hip sway.
for f, arm, elbow, head_x, head_y in (
        (0, 0, 0, 0, 0),
        (20, 58, -12, 6, 8),
        (40, 58, -12, 6, -8),
        (60, 0, 0, 0, 0)):
    bone_key("arm_L", f, rot=quat_axis("z", arm))
    bone_key("arm_R", f, rot=quat_axis("z", -arm))
    bone_key("elbow_L", f, rot=quat_axis("x", elbow))
    bone_key("elbow_R", f, rot=quat_axis("x", elbow))
    bone_key("head", f, rot=quat_axis("x", head_x) if f != 0 else (0, 0, 0, 1))
    bone_key("center", f, rot=quat_axis("y", head_y * 0.4))
    bone_key("hair_L", f, rot=quat_axis("x", head_y * 0.7))
    bone_key("hair_R", f, rot=quat_axis("x", head_y * 0.7))

morph_frames = [("smile", 0, 0.0), ("smile", 20, 1.0), ("smile", 40, 1.0), ("smile", 60, 0.0)]

camera_frames = []
for f, ry in ((0, 0.0), (30, 0.32), (60, 0.0)):
    camera_frames.append((f, 18.0, (0.0, 4.4, 0.0), (0.0, ry, 0.0), 30))

vmd = bytearray()
vmd += b"Vocaloid Motion Data 0002".ljust(30, b"\0")
vmd += text_sjis("SampleMotion", 20)
vmd += u32(len(bone_frames))
for name, frame, pos, rot in bone_frames:
    vmd += text_sjis(name, 15)
    vmd += u32(frame)
    vmd += vec3(pos)
    vmd += vec4(rot)
    vmd += default_bone_interp()
vmd += u32(len(morph_frames))
for name, frame, weight in morph_frames:
    vmd += text_sjis(name, 15)
    vmd += u32(frame)
    vmd += f32(weight)
vmd += u32(len(camera_frames))
for frame, distance, pos, rot, fov in camera_frames:
    vmd += u32(frame)
    vmd += f32(distance)
    vmd += vec3(pos)
    vmd += vec3(rot)
    vmd += default_camera_interp()
    vmd += u32(fov)
    vmd += u8(0)
# optional trailing sections (light / self shadow / IK) as empty counts
vmd += u32(0) + u32(0) + u32(0)

with open(os.path.join(OUT_DIR, "sample.vmd"), "wb") as f:
    f.write(vmd)

print("VMD written", len(vmd), "bytes,", len(bone_frames), "bone keys,", len(camera_frames), "camera keys")
