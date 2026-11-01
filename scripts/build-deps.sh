#!/usr/bin/env bash
# iOS 기기(arm64)용 OpenSSL · FreeRDP 정적 라이브러리를 Vendor/ 에 만든다.
# CI(macOS)에서 돌린다. Mac 에서 직접 돌리려면 Xcode 와 cmake · ninja · pkg-config 가 있어야 한다.
set -euo pipefail

FREERDP_VERSION=3.32.2
# FreeRDP 3.32.2 의 client/iOS/cmake/DepVersions.cmake 가 고정한 판과 해시
OPENSSL_VERSION=openssl-4.0.1
OPENSSL_SHA256=2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09
DEPLOYMENT_TARGET=16.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/deps"
PREFIX="$ROOT/Vendor"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$WORK" "$PREFIX"

if [ ! -f "$PREFIX/lib/libssl.a" ]; then
  cd "$WORK"
  curl -fsSL -o openssl.tar.gz \
    "https://github.com/openssl/openssl/releases/download/$OPENSSL_VERSION/$OPENSSL_VERSION.tar.gz"
  echo "$OPENSSL_SHA256  openssl.tar.gz" | shasum -a 256 -c -
  rm -rf "$OPENSSL_VERSION"
  tar xzf openssl.tar.gz
  cd "$OPENSSL_VERSION"
  # upstream client/iOS/cmake/ExternalOpenSSL.cmake 와 같은 방식(iphoneos-cross), 공유 대신 정적.
  # Makefile 이 -isysroot $(CROSS_TOP)/SDKs/$(CROSS_SDK) 를 make 변수로 쓰므로 make 단계에도 같은 환경이 있어야 한다.
  (
    export CROSS_TOP="$(xcode-select -print-path)/Platforms/iPhoneOS.platform/Developer"
    export CROSS_SDK="iPhoneOS.sdk"
    export CC="$(xcrun --sdk iphoneos --find clang) -arch arm64 -miphoneos-version-min=$DEPLOYMENT_TARGET"
    perl Configure iphoneos-cross no-shared no-tests no-apps no-docs \
      --prefix="$PREFIX" --libdir=lib
    make -j"$JOBS" build_sw
    make install_sw
  )
fi

if [ ! -f "$PREFIX/lib/libfreerdp3.a" ]; then
  cd "$WORK"
  rm -rf freerdp freerdp-build
  git clone -q --depth 1 --branch "$FREERDP_VERSION" https://github.com/FreeRDP/FreeRDP.git freerdp
  # 옵션은 upstream client/iOS/cmake/ExternalFreeRDP.cmake 를 따르고, 코덱·오디오·스마트카드처럼
  # 이 앱이 쓰지 않는 것은 끈다. WITH_INTERNAL_RC4/MD4/MD5 가 없으면 Windows 의 NLA(NTLM) 로그인이 실패한다.
  cmake -S freerdp -B freerdp-build -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$WORK/freerdp/cmake/ios.toolchain.cmake" \
    -DPLATFORM=OS64 \
    -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DWITH_OPENSSL=ON \
    -DOPENSSL_ROOT_DIR="$PREFIX" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    -DWITH_INTERNAL_RC4=ON \
    -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_MD5=ON \
    -DWITHOUT_WINPR_3x_DEPRECATED=ON \
    -DWITHOUT_FREERDP_3x_DEPRECATED=ON \
    -DWITH_CLIENT=OFF \
    -DWITH_CLIENT_SDL=OFF \
    -DWITH_SAMPLE=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_PROXY=OFF \
    -DWITH_SHADOW=OFF \
    -DWITH_WINPR_TOOLS=OFF \
    -DWITH_MANPAGES=OFF \
    -DWITH_SYSTEMD=OFF \
    -DWITH_JSON_DISABLED=ON \
    -DWITH_CJSON=OFF \
    -DWITH_AAD=OFF \
    -DWITH_KRB5=OFF \
    -DWITH_PKCS11=OFF \
    -DWITH_SMARTCARD_EMULATE=OFF \
    -DWITH_FUSE=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_VIDEOTOOLBOX=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_VIDEO_FFMPEG=OFF \
    -DWITH_DSP_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_OPUS=OFF \
    -DWITH_OPENH264=OFF \
    -DWITH_JPEG=OFF \
    -DWITH_URIPARSER=OFF \
    -DWINPR_UTILS_IMAGE_PNG=OFF \
    -DWINPR_UTILS_IMAGE_WEBP=OFF \
    -DWINPR_UTILS_IMAGE_JPEG=OFF \
    -DCHANNEL_RDPSND=OFF \
    -DCHANNEL_AUDIN=OFF \
    -DCHANNEL_URBDRC=OFF \
    -DCHANNEL_PRINTER=OFF \
    -DCHANNEL_SMARTCARD=OFF
  cmake --build freerdp-build -j "$JOBS"
  cmake --install freerdp-build
fi

# 앱이 -lfreerdp-all 하나만 링크하도록 정적 라이브러리를 하나로 합친다.
cd "$PREFIX/lib"
rm -f libfreerdp-all.a
LIBS=$(find . -maxdepth 1 -name 'lib*.a' ! -name 'libfreerdp-all.a' | sort)
echo "합치는 라이브러리:"
echo "$LIBS"
# shellcheck disable=SC2086
libtool -static -no_warning_for_no_symbols -o libfreerdp-all.a $LIBS
ls -la "$PREFIX/lib"
