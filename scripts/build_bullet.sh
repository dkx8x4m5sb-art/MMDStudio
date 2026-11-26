#!/usr/bin/env bash
# 把 ThirdParty/bullet 编成 iOS 静态库。
#
# Bullet 官方提供三个 unity 构建入口（btLinearMathAll / btBulletCollisionAll /
# btBulletDynamicsAll），每个入口用 #include 把整个模块的 .cpp 串成一个编译
# 单元，所以整个引擎只需要三次编译调用，不用维护 150 条文件清单。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ThirdParty/bullet/src"
OUT="${OUT_DIR:-$ROOT/build/bullet}"
SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
MIN_IOS="${MIN_IOS:-17.0}"
ARCH="${ARCH:-arm64}"

if [ ! -d "$SRC/BulletDynamics" ]; then
  echo "错误：找不到 $SRC，ThirdParty/bullet 不完整。" >&2
  exit 1
fi

mkdir -p "$OUT/obj"

CXXFLAGS=(
  -std=gnu++20
  -O3
  -fPIC
  -fvisibility=hidden
  -fvisibility-inlines-hidden
  -DNDEBUG
  -isysroot "$SDK"
  -target "${ARCH}-apple-ios${MIN_IOS}"
  -I"$SRC"
  -Wno-deprecated-declarations
  -Wno-unused-variable
)

# Bullet 的 unity 文件把上百个 .cpp 串成一个 TU，内存峰值比常规编译高，
# 但换来的是三次编译而不是一百五十次。
for unit in btLinearMathAll btBulletCollisionAll btBulletDynamicsAll; do
  echo "编译 $unit.cpp ..."
  xcrun --sdk iphoneos clang++ "${CXXFLAGS[@]}" \
    -c "$SRC/$unit.cpp" -o "$OUT/obj/$unit.o"
done

echo "打包 libbullet.a ..."
xcrun libtool -static -o "$OUT/libbullet.a" "$OUT"/obj/*.o
echo "产物：$OUT/libbullet.a ($(du -h "$OUT/libbullet.a" | cut -f1))"
