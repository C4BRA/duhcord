#!/bin/bash
# Builds Discord's libdave (end-to-end encryption for voice, the DAVE protocol) and its dependencies from source,
# each pinned to an exact commit, into one static library for the voice helper: Vendor/libdave/lib/libCDave.a.
#
# Only the voice helper (Sources/DuhcordVoice) links it. It runs in its own sandboxed process that never sees the
# Discord login token, so a bug in this C++ can't reach the token.
#
# The dependencies are built directly with CMake instead of through libdave's vcpkg setup, at the same versions
# libdave's own manifests pin, so the build needs no vcpkg checkout and nothing is resolved at build time.
# Usage: scripts/build-libdave.sh      (skips the build if the pinned version is already built)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

LIBDAVE_COMMIT=6396c90aedbb9a6ee117ea9ce1ce9832af6a3375  # libdave v1.2.2/cpp
MLSPP_COMMIT=1cc50a124a3bc4e143a787ec934280dc70c1034d    # the version libdave's mlspp overlay port pins
BORINGSSL_COMMIT=58f3bc83230d2958bb9710bc910972c4f5d382dc # 0.20240913.0, libdave's vcpkg baseline
JSON_COMMIT=9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03      # nlohmann/json v3.11.3, the same baseline
PINS="$LIBDAVE_COMMIT $MLSPP_COMMIT $BORINGSSL_COMMIT $JSON_COMMIT"

OUT="$ROOT/Vendor/libdave"
LIB="$OUT/lib/libCDave.a"
STAMP="$OUT/lib/pins"
if [ -f "$LIB" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$PINS" ]; then
    echo "libdave is up to date ($LIB)"
    exit 0
fi

SRC="$OUT/src"
PREFIX="$OUT/prefix"
rm -rf "$SRC" "$PREFIX" "$OUT/lib"
mkdir -p "$SRC" "$PREFIX" "$OUT/lib"

# Fetches exactly one commit; a moved tag or branch can't change what gets built.
fetch() {
    local url="$1" commit="$2" dir="$SRC/$3"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" checkout -q FETCH_HEAD
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "error: $url didn't give $commit" >&2; exit 1; }
}

fetch https://github.com/nlohmann/json.git "$JSON_COMMIT" json
fetch https://github.com/google/boringssl.git "$BORINGSSL_COMMIT" boringssl
fetch https://github.com/cisco/mlspp.git "$MLSPP_COMMIT" mlspp
fetch https://github.com/discord/libdave.git "$LIBDAVE_COMMIT" libdave

# Warnings stay on but don't fail the build: a newer Xcode adding a warning shouldn't break CI.
sed -i '' 's/-Werror //' "$SRC/boringssl/CMakeLists.txt"
sed -i '' 's/ -Werror//' "$SRC/mlspp/CMakeLists.txt" "$SRC/libdave/cpp/CMakeLists.txt"
# libdave doesn't use these mlspp parts (its overlay port removes them too).
sed -i '' '/add_subdirectory(mls_ds)/d; /add_subdirectory(mls_vectors)/d' "$SRC/mlspp/lib/CMakeLists.txt"

JOBS="$(sysctl -n hw.ncpu)"
COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_PREFIX_PATH="$PREFIX"
    -DBUILD_SHARED_LIBS=OFF
)
# BoringSSL is used straight from its build folder, standing in for OpenSSL.
OPENSSL=(
    -DOPENSSL_INCLUDE_DIR="$SRC/boringssl/include"
    -DOPENSSL_CRYPTO_LIBRARY="$SRC/boringssl/build/libcrypto.a"
    -DOPENSSL_SSL_LIBRARY="$SRC/boringssl/build/libssl.a"
)

cmake -S "$SRC/json" -B "$SRC/json/build" "${COMMON[@]}" -DJSON_BuildTests=OFF
cmake --install "$SRC/json/build"

cmake -S "$SRC/boringssl" -B "$SRC/boringssl/build" "${COMMON[@]}"
cmake --build "$SRC/boringssl/build" --target crypto ssl -j "$JOBS"

cmake -S "$SRC/mlspp" -B "$SRC/mlspp/build" "${COMMON[@]}" "${OPENSSL[@]}" \
    -DDISABLE_GREASE=ON -DMLS_CXX_NAMESPACE=mlspp -DREQUIRE_BORINGSSL=ON -DTESTING=OFF
cmake --build "$SRC/mlspp/build" -j "$JOBS"
cmake --install "$SRC/mlspp/build"

cmake -S "$SRC/libdave/cpp" -B "$SRC/libdave/build" "${COMMON[@]}" "${OPENSSL[@]}" \
    -DREQUIRE_BORINGSSL=ON -DTESTING=OFF -DPERSISTENT_KEYS=OFF
cmake --build "$SRC/libdave/build" --target libdave -j "$JOBS"

# One archive for the helper to link. The linker keeps only what the helper uses.
libtool -static -o "$LIB" \
    "$SRC/libdave/build/libdave.a" "$PREFIX"/lib/*.a "$SRC/boringssl/build/libcrypto.a"

# The C header Duhcord compiles against is committed (Sources/CDave/include/dave.h) and must match this build.
if ! cmp -s "$SRC/libdave/cpp/includes/dave/dave.h" "$ROOT/Sources/CDave/include/dave.h"; then
    echo "error: Sources/CDave/include/dave.h differs from libdave $LIBDAVE_COMMIT; copy the new header in" >&2
    exit 1
fi

# License notices for everything linked in.
mkdir -p "$OUT/licenses"
cp "$SRC/libdave/LICENSE" "$OUT/licenses/libdave"
cp "$SRC/mlspp/LICENSE" "$OUT/licenses/mlspp"
cp "$SRC/boringssl/LICENSE" "$OUT/licenses/boringssl"
cp "$SRC/json/LICENSE.MIT" "$OUT/licenses/nlohmann-json"

echo "$PINS" > "$STAMP"
rm -rf "$SRC" "$PREFIX"
echo "Built $LIB ($(du -h "$LIB" | cut -f1))"
