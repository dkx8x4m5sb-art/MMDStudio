# Video → VMD tools

## In-app (experimental)

MMD Studio 的「视频转动作」页面调用 Apple Vision 的人体姿态估计。它不需要下载模型，适合快速尝试；单目 2D/伪 3D 结果对遮挡、快速旋转和机位变化比较敏感。

## Desktop, open source (MediaPipe)

`video_to_vmd.py` 使用 Google MediaPipe Pose（Apache-2.0）做离线转换，生成标准 VMD 0002 文件，之后在 MMD Studio 中通过「导入 VMD」载入。

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install opencv-python mediapipe numpy
python3 video_to_vmd.py dance.mp4 dance.vmd --fps 30
```

限制：单目视频没有真实深度，脚本输出的动作适合作为基础节奏/姿态参考，不能替代专业动作捕捉；快速旋转、遮挡、多人画面需要先裁剪成单人正面全身视频。
