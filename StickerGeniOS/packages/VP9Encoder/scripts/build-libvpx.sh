#!/bin/zsh
# Builds libvpx (VP9 encoder + decoder only) as a static xcframework for iOS devices and the
# simulator, from a pinned upstream tag, with nothing GPL or "nonfree" anywhere in the tree.
#
#   scripts/build-libvpx.sh            # clones libvpx at LIBVPX_TAG into a temp dir and builds
#   LIBVPX_SOURCE=/path/to/libvpx scripts/build-libvpx.sh
#
# Output: ../libvpx.xcframework (next to Package.swift), plus LICENSE, PATENTS and the exact
# configure line under ../ThirdPartyNotices/libvpx/ so the binary can be reproduced.
#
# Only the VP9 codec is built: VP8, the examples, tools, docs, unit tests, libwebm and libyuv are
# all switched off. The decoder is kept so the package's own tests can decode what the encoder
# wrote. The x86_64 simulator slice disables every x86 SIMD path so no assembler (yasm/nasm) is
# needed; arm64 uses NEON intrinsics, which clang compiles on its own.
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PACKAGE_ROOT=${SCRIPT_DIR:h}
LIBVPX_TAG=${LIBVPX_TAG:-v1.15.2}
LIBVPX_REPO=${LIBVPX_REPO:-https://chromium.googlesource.com/webm/libvpx}
IOS_MIN=${IOS_MIN:-17.0}
WORK=${LIBVPX_WORK:-$(mktemp -d /tmp/libvpx-build.XXXXXX)}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}

if [[ -n "${LIBVPX_SOURCE:-}" ]]; then
  SOURCE=${LIBVPX_SOURCE}
else
  SOURCE=${WORK}/libvpx
  if [[ ! -d "${SOURCE}" ]]; then
    git clone --depth 1 --branch "${LIBVPX_TAG}" "${LIBVPX_REPO}" "${SOURCE}"
  fi
fi

COMMON_FLAGS=(
  --disable-vp8
  --enable-vp9
  --enable-vp9-encoder
  --enable-vp9-decoder
  --disable-vp9-highbitdepth
  --disable-examples
  --disable-tools
  --disable-docs
  --disable-unit-tests
  --disable-webm-io
  --disable-libyuv
  --disable-postproc
  --disable-vp9-postproc
  --disable-shared
  --enable-static
  --enable-pic
  --disable-install-docs
  --disable-install-bins
  --disable-install-srcs
)
X86_NO_ASM=(
  --disable-mmx --disable-sse --disable-sse2 --disable-sse3 --disable-ssse3
  --disable-sse4_1 --disable-avx --disable-avx2 --disable-avx512
  --disable-runtime-cpu-detect
)

SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

build_slice() {
  local name=$1; shift
  local target=$1; shift
  local build=${WORK}/build-${name}
  rm -rf "${build}"; mkdir -p "${build}"
  (
    cd "${build}"
    "${SOURCE}/configure" --target="${target}" "${COMMON_FLAGS[@]}" "$@" > configure.log 2>&1 \
      || { cat configure.log >&2; exit 1; }
    make -j"${JOBS}" > make.log 2>&1 || { tail -50 make.log >&2; exit 1; }
  ) || exit 1
  [[ -f "${build}/libvpx.a" ]] || { echo "no libvpx.a produced in ${build}" >&2; exit 1; }
  echo "${build}/libvpx.a"
}

echo "== libvpx ${LIBVPX_TAG}: iOS device arm64"
DEVICE_LIB=$(build_slice ios-arm64 arm64-darwin-gcc \
  --extra-cflags="-miphoneos-version-min=${IOS_MIN}")

# Simulator slices go through the plain darwin (macOS-style) toolchain path, which honours the
# CC/CXX/LD environment, and every tool is a wrapper that appends the simulator SDK and target
# triple *after* whatever configure added. The device-only iOS toolchain block cannot be used: it
# hard-codes the iPhoneOS SDK into every compile and link check, so simulator objects fail its
# link probe. The x86_64 slice disables all x86 SIMD, so no .asm file is ever assembled and the
# `AS=yasm` below is never invoked — it only satisfies configure's assembler check.
make_sim_wrapper() {
  local tool=$1 out=$2 flags=$3
  cat > "${out}" <<WRAP
#!/bin/sh
exec "${tool}" "\$@" ${flags}
WRAP
  chmod +x "${out}"
}

sim_slice() {
  local name=$1 arch=$2; shift 2
  local flags="-isysroot ${SIM_SDK} -target ${arch}-apple-ios${IOS_MIN}-simulator"
  local bin=${WORK}/${name}-toolchain
  mkdir -p "${bin}"
  make_sim_wrapper "$(xcrun --sdk iphonesimulator --find clang)" "${bin}/cc" "${flags}"
  make_sim_wrapper "$(xcrun --sdk iphonesimulator --find clang++)" "${bin}/cxx" "${flags}"
  CC="${bin}/cc" CXX="${bin}/cxx" LD="${bin}/cxx" AS="${bin}/cc" \
    AR="$(xcrun --sdk iphonesimulator --find ar)" STRIP="$(xcrun --sdk iphonesimulator --find strip)" \
    build_slice "${name}" "${arch}-darwin20-gcc" "$@"
}

echo "== libvpx ${LIBVPX_TAG}: simulator arm64"
SIM_ARM64_LIB=$(sim_slice sim-arm64 arm64)

echo "== libvpx ${LIBVPX_TAG}: simulator x86_64"
SIM_X86_LIB=$(AS=yasm sim_slice sim-x86_64 x86_64 "${X86_NO_ASM[@]}")

# The iOS toolchain still adds -fembed-bitcode, which Xcode no longer ships anywhere; the
# sections it leaves in every object are dead weight that triples the device slice.
xcrun bitcode_strip -r "${DEVICE_LIB}" -o "${DEVICE_LIB}"

SIM_FAT=${WORK}/libvpx-simulator.a
lipo -create "${SIM_ARM64_LIB}" "${SIM_X86_LIB}" -output "${SIM_FAT}"

# The xcframework ships libraries only. Its public headers are compiled into the CVPX shim
# target instead (see the copy below), so exactly one module owns them — a second copy inside the
# xcframework would make clang see the same header in two modules.
OUT=${PACKAGE_ROOT}/libvpx.xcframework
rm -rf "${OUT}"
xcodebuild -create-xcframework \
  -library "${DEVICE_LIB}" \
  -library "${SIM_FAT}" \
  -output "${OUT}"

NOTICES=${PACKAGE_ROOT}/ThirdPartyNotices/libvpx
mkdir -p "${NOTICES}"
cp "${SOURCE}/LICENSE" "${NOTICES}/LICENSE"
cp "${SOURCE}/PATENTS" "${NOTICES}/PATENTS"
cp "${SOURCE}/AUTHORS" "${NOTICES}/AUTHORS" 2>/dev/null || true
{
  echo "libvpx ${LIBVPX_TAG} (${LIBVPX_REPO})"
  echo "commit: $(git -C "${SOURCE}" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(xcodebuild -version | tr '\n' ' ')"
  echo "minimum iOS: ${IOS_MIN}"
  echo "common configure flags: ${COMMON_FLAGS[*]}"
  echo "x86_64 simulator extra flags: ${X86_NO_ASM[*]}"
} > "${NOTICES}/BUILD-INFO.txt"

# Refresh the public headers the C shim compiles against, so they always match the binary.
SHIM_INCLUDE=${PACKAGE_ROOT}/Sources/CVPX/include/vpx
mkdir -p "${SHIM_INCLUDE}"
cp "${SOURCE}"/vpx/*.h "${SHIM_INCLUDE}/"

echo "== wrote ${OUT}"
du -sh "${OUT}"
