#!/usr/bin/env bash
# Build a portable Linux x86-64 LLVM toolchain (clang, clang-cl, lld, clang
# tools, compiler-rt) inside manylinux_2_28, so the binaries need only GlibC
# 2.28 and the system libstdc++ (gcc-toolset links its newer bits statically).
#
#   lilian/build-release.sh            # build and package
#   lilian/build-release.sh --publish  # also create a GitHub Release
set -euo pipefail

src=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
build=${LILIAN_BUILD_DIR:-${src}-build}
image=quay.io/pypa/manylinux_2_28_x86_64
revision=$(git -C "${src}" rev-parse --short=12 HEAD)
name=llvm-lilian-${revision}-x86_64-linux
mkdir -p "${build}"

podman run --rm -v "${src}:/src:ro,z" -v "${build}:/build:z" -w /build "${image}" bash -euo pipefail -c "
  dnf install -y -q --disablerepo=epel lld >/dev/null
  # The just-built clang compiles compiler-rt; aim it at gcc-toolset's
  # libstdc++ (the system GCC 8 lacks one). This config is not installed.
  mkdir -p /build/obj/bin
  echo --gcc-install-dir=\$(dirname \$(gcc -print-libgcc-file-name)) > /build/obj/bin/x86_64-unknown-linux-gnu.cfg
  pipx install -q ninja && export PATH=\$PATH:/root/.local/bin && ninja --version
  git config --global --add safe.directory /src
  cmake -S /src/llvm -B /build/obj -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/build/${name} \
    -DLLVM_ENABLE_PROJECTS='clang;clang-tools-extra;lld' \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DCLANG_LINK_CLANG_DYLIB=ON \
    -DLLVM_USE_LINKER=lld \
    -DLLVM_PARALLEL_LINK_JOBS=3 \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_ZLIB=ON \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_Z3_SOLVER=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF
  ninja -C /build/obj install/strip
  rm -rf /build/${name}/include /build/${name}/lib/cmake /build/${name}/share/man
  find /build/${name}/lib -maxdepth 1 -name '*.a' -delete
"

tar -C "${build}" -cf - "${name}" | zstd -T0 -19 -o "${build}/${name}.tar.zst" -f
(cd "${build}" && sha256sum "${name}.tar.zst") | tee "${build}/${name}.tar.zst.sha256"

if [[ "${1:-}" == --publish ]]; then
  git -C "${src}" push origin "HEAD:refs/heads/lilian"
  gh release create "lilian-${revision}" --repo Cons-Cat/llvm-project \
    --target "$(git -C "${src}" rev-parse HEAD)" --title "llvm-lilian ${revision}" \
    --notes "Portable Linux x86-64 toolchain from \`lilian\` at ${revision} (GlibC 2.28+)." \
    "${build}/${name}.tar.zst" "${build}/${name}.tar.zst.sha256"
fi
