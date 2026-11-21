#!/usr/bin/env bash
# Build a portable Linux x86-64 LLVM toolchain (clang, clang-cl, lld, BOLT,
# clang tools, compiler-rt) inside manylinux_2_28, so the binaries need only
# GlibC 2.28 and the system libstdc++ (gcc-toolset links its newer bits
# statically). The toolchain is then optimized with BOLT, following
# `bolt/docs/OptimizingClang.md`, from an LBR profile of a clean libCat build.
# This needs `perf`, `mise`, and a CPU with taken-branch sampling.
#
#   lilian/build-release.sh <libCat>            # build and package
#   lilian/build-release.sh <libCat> --publish  # also create a GitHub Release
set -euo pipefail

libcat=$(realpath "$1")
src=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
build=${LILIAN_BUILD_DIR:-${src}-build}
image=quay.io/pypa/manylinux_2_28_x86_64
revision=$(git -C "${src}" rev-parse --short=12 HEAD)
name=llvm-lilian-${revision}-x86_64-linux
toolchain=${build}/${name}
libxml2=libxml2-2.13.9
libxml2_sha256=a2c9ae7b770da34860050c309f903221c67830c86e4a7e760692b803df95143a
mkdir -p "${build}"

podman run --rm -v "${src}:/src:ro,z" -v "${build}:/build:z" -w /build "${image}" bash -euo pipefail -c "
  dnf install -y -q --disablerepo=epel lld >/dev/null
  # The just-built clang compiles compiler-rt; aim it at gcc-toolset's
  # libstdc++ (the system GCC 8 lacks one). This config is not installed.
  mkdir -p /build/obj/bin
  echo --gcc-install-dir=\$(dirname \$(gcc -print-libgcc-file-name)) > /build/obj/bin/x86_64-unknown-linux-gnu.cfg
  pipx install -q ninja && export PATH=\$PATH:/root/.local/bin && ninja --version
  git config --global --add safe.directory /src

  # \`llvm-mt\`, which CMake needs to target Windows with clang-cl, requires
  # libxml2. Link it statically, because its soname differs across distros.
  if [[ ! -f /build/libxml2/lib/libxml2.a ]]; then
    curl -fsSL https://download.gnome.org/sources/libxml2/2.13/${libxml2}.tar.xz -o /build/${libxml2}.tar.xz
    echo '${libxml2_sha256}  /build/${libxml2}.tar.xz' | sha256sum -c
    tar -C /build -xf /build/${libxml2}.tar.xz
    cmake -S /build/${libxml2} -B /build/libxml2-obj -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/build/libxml2 \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DBUILD_SHARED_LIBS=OFF \
      -DLIBXML2_WITH_ICONV=OFF \
      -DLIBXML2_WITH_ICU=OFF \
      -DLIBXML2_WITH_LZMA=OFF \
      -DLIBXML2_WITH_ZLIB=OFF \
      -DLIBXML2_WITH_PYTHON=OFF \
      -DLIBXML2_WITH_PROGRAMS=OFF \
      -DLIBXML2_WITH_TESTS=OFF
    ninja -C /build/libxml2-obj install
  fi

  # \`-Wl,-q\` keeps the relocations that BOLT needs. The toolchain is
  # installed unstripped, and stripped after BOLT runs.
  cmake -S /src/llvm -B /build/obj -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/build/${name} \
    -DCMAKE_EXE_LINKER_FLAGS=-Wl,-q \
    -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-q \
    -DLLVM_ENABLE_PROJECTS='bolt;clang;clang-tools-extra;lld' \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DCLANG_LINK_CLANG_DYLIB=ON \
    -DLLVM_USE_LINKER=lld \
    -DLLVM_PARALLEL_COMPILE_JOBS=8 \
    -DLLVM_PARALLEL_LINK_JOBS=2 \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_ZLIB=ON \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=FORCE_ON \
    -DLIBXML2_INCLUDE_DIR=/build/libxml2/include/libxml2 \
    -DLIBXML2_LIBRARY=/build/libxml2/lib/libxml2.a \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_Z3_SOLVER=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF
  rm -rf /build/${name}
  ninja -C /build/obj install
  rm -rf /build/${name}/include /build/${name}/lib/cmake /build/${name}/share/man
  find /build/${name}/lib -maxdepth 1 -name '*.a' ! -name 'libbolt_rt_*' -delete
"

# Profile a clean libCat build, with examples and tests, in both its Debug and
# Release configurations. sccache would skip compiling, so it is disabled.
# Flags inherited from the caller's environment are dropped, so the profile is
# reproducible.
train=${build}/train
rm -rf "${train}"
(
  cd "${libcat}"
  mise exec -- bash -euo pipefail -c "
    unset CFLAGS CXXFLAGS LDFLAGS
    export PATH='${toolchain}/bin':\$PATH
    cmake -S . -B '${train}' -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCAT_USE_SCCACHE=OFF
    perf record -F 1000 -e cycles:u -j any,u -o '${build}/perf.data' -- \
      bash -c \"cmake --build '${train}' --config Debug && cmake --build '${train}' --config Release\"
  "
)

# Clang and lld spend nearly all of their time in these. GCC leaves data
# relocations that BOLT cannot attribute to a function, so `perf2bolt` must
# not run in strict mode, and `llvm-bolt` must optimize each function in place
# (`-relocs=0`). Moving functions leaves those references stale, which makes
# clang hang.
for binary in "${toolchain}"/lib/libLLVM.so.*git "${toolchain}"/lib/libclang-cpp.so.*git "${toolchain}/bin/lld"; do
  "${toolchain}/bin/perf2bolt" "${binary}" -p "${build}/perf.data" -o "${binary}.fdata" -strict=0
  "${toolchain}/bin/llvm-bolt" "${binary}" -o "${binary}.bolt" -data "${binary}.fdata" \
    -relocs=0 -reorder-blocks=ext-tsp -split-functions -dyno-stats -use-gnu-stack
  mv "${binary}.bolt" "${binary}"
  rm "${binary}.fdata"
done
rm -rf "${build}/perf.data" "${train}"

find "${toolchain}/bin" "${toolchain}/lib" -maxdepth 1 -type f ! -name '*.a' |
  while read -r file; do
    if [[ $(head -c 4 "${file}") == $'\x7fELF' ]]; then
      "${toolchain}/bin/llvm-strip" "${file}"
    fi
  done

tar -C "${build}" -cf - "${name}" | zstd -T0 -19 -o "${build}/${name}.tar.zst" -f
(cd "${build}" && sha256sum "${name}.tar.zst") | tee "${build}/${name}.tar.zst.sha256"

if [[ "${2:-}" == --publish ]]; then
  git -C "${src}" push --force-with-lease origin "HEAD:refs/heads/lilian"
  gh release create "lilian-${revision}" --repo Cons-Cat/llvm-project \
    --target "$(git -C "${src}" rev-parse HEAD)" --title "llvm-lilian ${revision}" \
    --notes "Portable Linux x86-64 toolchain from \`lilian\` at ${revision} (GlibC 2.28+), optimized with BOLT. Includes clang-cl, lld-link, llvm-mt, llvm-lib, and llvm-rc for cross-compiling to Windows, and llvm-bolt, perf2bolt, and merge-fdata." \
    "${build}/${name}.tar.zst" "${build}/${name}.tar.zst.sha256"
fi
