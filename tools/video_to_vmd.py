#!/usr/bin/env python3
"""Offline video -> VMD converter using MediaPipe Holistic/Pose (Apache-2.0).

This is the higher-quality desktop companion to the experimental in-app
Vision extractor. It samples a video, estimates 3D body landmarks, converts
the major limb angles into local bone rotations and writes VMD 0002.

Example:
    python3 tools/video_to_vmd.py dance.mp4 dance.vmd --fps 30
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
from pathlib import Path

try:
    import cv2
    import mediapipe as mp
    import numpy as np
except ImportError as exc:
    sys.exit(f"缺少依赖：{exc}. 请先运行: pip install opencv-python mediapipe numpy")


def shift_jis_bytes(text: str, length: int) -> bytes:
    raw = text.encode("shift_jis", errors="ignore")[:length]
    return raw + b"\x00" * (length - len(raw))


def linear_interpolation() -> bytes:
    data = bytearray(64)
    for channel in range(4):
        data[channel] = 20
        data[channel + 4] = 20
        data[channel + 8] = 107
        data[channel + 12] = 107
    return bytes(data)


def quat_z(angle: float) -> tuple[float, float, float, float]:
    return (0.0, 0.0, math.sin(angle / 2), math.cos(angle / 2))


def angle(a, b) -> float:
    return math.atan2(b[1] - a[1], b[0] - a[0])


def delta(value: float) -> float:
    return math.atan2(math.sin(value), math.cos(value))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--sample-fps", type=float, default=20.0)
    args = parser.parse_args()

    capture = cv2.VideoCapture(str(args.input))
    if not capture.isOpened():
        sys.exit("无法打开视频")

    source_fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
    frame_step = max(1, int(round(source_fps / args.sample_fps)))
    total_frames = int(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0)

    tracks: dict[str, list[tuple[int, tuple[float, float, float, float]]]] = {}

    def add(name: str, rotation: tuple[float, float, float, float] | None) -> None:
        if rotation is not None:
            tracks.setdefault(name, []).append((out_frame, rotation))

    pose = mp.solutions.pose.Pose(
        static_image_mode=False,
        model_complexity=2,
        enable_segmentation=False,
        min_detection_confidence=0.5,
        min_tracking_confidence=0.5,
    )

    index = 0
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        if index % frame_step != 0:
            index += 1
            continue
        out_frame = int(round(index / source_fps * args.fps))
        result = pose.process(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        index += 1
        if not result.pose_landmarks:
            continue

        # MediaPipe image landmarks: x right, y down, z away from camera.
        # Flip y to a y-up model space.
        points = {landmark.name: (lm.x, -lm.y, lm.z)
                  for landmark, lm in zip(mp.solutions.pose.PoseLandmark,
                                          result.pose_landmarks.landmark)}

        def p(name: str):
            return points.get(name)

        def angle2(a, b):
            return math.atan2(b[1] - a[1], b[0] - a[0])

        hip = p("LEFT_HIP")
        neck = p("LEFT_SHOULDER")
        lean = 0.0
        if hip and neck:
            lean = angle2(hip, neck) - math.pi / 2

        add("センター", quat_z(-lean * 0.65))
        nose = p("NOSE")
        if neck and nose:
            add("頭", quat_z(-(angle2(neck, nose) - math.pi / 2 - lean)))

        ls, le, lw = p("LEFT_SHOULDER"), p("LEFT_ELBOW"), p("LEFT_WRIST")
        rs, re, rw = p("RIGHT_SHOULDER"), p("RIGHT_ELBOW"), p("RIGHT_WRIST")
        if ls and le:
            add("左腕", quat_z(-(angle2(ls, le) - lean)))
        if rs and re:
            add("右腕", quat_z(-(delta(angle2(rs, re) - math.pi) - lean)))
        if ls and le and lw:
            add("左ひじ", quat_z(-delta(angle2(le, lw) - angle2(ls, le))))
        if rs and re and rw:
            add("右ひじ", quat_z(-delta(angle2(re, rw) - angle2(rs, re))))

        lh, lk, la = p("LEFT_HIP"), p("LEFT_KNEE"), p("LEFT_ANKLE")
        rh, rk, ra = p("RIGHT_HIP"), p("RIGHT_KNEE"), p("RIGHT_ANKLE")
        if lh and lk:
            add("左足", quat_z(-(delta(angle2(lh, lk) + math.pi / 2) - lean)))
        if rh and rk:
            add("右足", quat_z(-(delta(angle2(rh, rk) + math.pi / 2) - lean)))
        if lh and lk and la:
            add("左ひざ", quat_z(-delta(angle2(lk, la) - angle2(lh, lk))))
        if rh and rk and ra:
            add("右ひざ", quat_z(-delta(angle2(rk, ra) - angle2(rh, rk))))
        add("上半身", quat_z(-lean * 0.35))

        if total_frames and index % max(1, total_frames // 20) == 0:
            print(f"\r{index}/{total_frames}", end="", flush=True)

    capture.release()
    pose.close()
    print()

    if not tracks:
        sys.exit("没有检测到人体姿态")

    # VMD 0002 header (30 bytes), model name (20), bone key count (4).
    data = bytearray()
    data += shift_jis_bytes("Vocaloid Motion Data 0002", 30)
    data += shift_jis_bytes("MediaPipe Video Capture", 20)
    total_keys = sum(len(keys) for keys in tracks.values())
    data += struct.pack("<I", total_keys)
    for name in sorted(tracks):
        data += shift_jis_bytes(name, 15)
        for out_frame, q in sorted(tracks[name], key=lambda item: item[0]):
            data += struct.pack("<I", max(0, out_frame))
            data += struct.pack("<fff", 0, 0, 0)
            data += struct.pack("<ffff", -q[0], -q[1], q[2], q[3])
            data += linear_interpolation()
    data += struct.pack("<I", 0)  # morph keys
    data += struct.pack("<I", 0)  # camera keys
    args.output.write_bytes(bytes(data))
    print(f"已生成 {args.output}：{len(tracks)} 根骨骼，{total_keys} 个关键帧")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
