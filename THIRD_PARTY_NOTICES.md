# 第三方组件声明

本工程包含以下第三方代码：

## bcdec

- 文件：`MMDStudio/Core/bcdec.h`、`MMDStudio/Core/bcdec.c`
- 作者：Sergii "iOrange" Kudlai
- 来源：https://github.com/iOrange/bcdec
- 许可：MIT License（见 `bcdec.h` 文件末尾）或 CC0 / Public Domain（二选一）

## Bullet

- 目录：`ThirdParty/bullet`（裁剪自 Bullet 3.25，保留 LinearMath / BulletCollision / BulletDynamics）
- 作者：Erwin Coumans 与 Bullet 贡献者
- 来源：https://github.com/bulletphysics/bullet3
- 许可：zlib License（见 `ThirdParty/bullet/LICENSE.txt`）
- 说明：源码已裁剪并合并为 unity build，属于「修改过的源版本」，按 zlib 要求在此注明

## Apple 系统框架

Metal、MetalKit、SwiftUI、AVFoundation、Photos、ImageIO 等均为 Apple 平台系统框架，
随 iOS SDK 使用，不随本仓库分发。

> 本项目 v12 起不再依赖 Google MediaPipe（原用于视频转动作，该功能已从构建中移除）。
