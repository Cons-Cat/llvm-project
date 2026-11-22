#!/usr/bin/env bash
# Build a portable Linux x86-64 LLVM toolchain (clang, clang-cl, lld, BOLT,
# clang tools, compiler-rt for Linux and Windows) inside manylinux_2_28, so the
# binaries need only GlibC 2.28 and the system libstdc++ (gcc-toolset links its
# newer bits statically). It is compiled by the clang in libCat's mise cache
# with full LTO and PGO, and then optimized with BOLT, following
# `bolt/docs/OptimizingClang.md`. Both profiles come from a clean libCat build.
# This needs `perf`, `mise`, `xwin`, and a CPU with taken-branch sampling.
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
host_llvm=${libcat}/.cache/cat-llvm
train=${build}/train
mkdir -p "${build}"

# Run a script inside manylinux_2_28, with `ninja` on the `PATH` and
# `gcc_install_dir` set. The host clang needs gcc-toolset's libstdc++, because
# the system GCC 8 lacks one.
in_manylinux() {
  podman run --rm -v "${src}:/src:ro,z" -v "${build}:/build:z" -v "${host_llvm}:/host-llvm:ro,z" \
    -w /build "${image}" bash -euo pipefail -c "
    pipx install -q ninja && export PATH=\$PATH:/root/.local/bin
    git config --global --add safe.directory /src
    gcc_install_dir=\$(dirname \$(gcc -print-libgcc-file-name))
    $1"
}

# Build libCat's committed `HEAD`, with examples and tests, in both its Debug
# and Release configurations, with the clang in the directory `$1`, under the
# command `$2`. Edits in progress cannot break it, and flags inherited from the
# caller's environment are dropped, so the profiles are reproducible. sccache
# would skip compiling, so it is disabled.
train() {
  rm -rf "${train}"
  (
    cd "${libcat}"
    mise exec -- bash -euo pipefail -c "
      unset CFLAGS CXXFLAGS LDFLAGS
      export PATH='$1':\$PATH
      cmake -S '${build}/libcat' -B '${train}' -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCAT_USE_SCCACHE=OFF
      $2 bash -c \"cmake --build '${train}' --config Debug && cmake --build '${train}' --config Release\"
    "
  )
}

rm -rf "${build}/libcat"
mkdir "${build}/libcat"
git -C "${libcat}" archive HEAD | tar -C "${build}/libcat" -x

# The MSVC CRT and Windows SDK, to build compiler-rt for Windows. They are only
# used while building, and are not shipped.
if [[ ! -d ${build}/xwin ]]; then
  xwin --accept-license --cache-dir "${build}/xwin-cache" splat --output "${build}/xwin"
fi

# CMake reads `CFLAGS` and `CXXFLAGS` in every sub-build, such as BOLT's
# runtime, so the host clang finds libstdc++ there too.
llvm_options="
  export CFLAGS=--gcc-install-dir=\${gcc_install_dir} CXXFLAGS=--gcc-install-dir=\${gcc_install_dir}
  llvm_options='
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER=/host-llvm/bin/clang
    -DCMAKE_CXX_COMPILER=/host-llvm/bin/clang++
    -DCMAKE_AR=/host-llvm/bin/llvm-ar
    -DCMAKE_RANLIB=/host-llvm/bin/llvm-ranlib
    -DLLVM_USE_LINKER=/host-llvm/bin/ld.lld
    -DLLVM_TARGETS_TO_BUILD=X86
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_ENABLE_ZLIB=ON
    -DLLVM_ENABLE_ZSTD=OFF
    -DLLVM_ENABLE_LIBEDIT=OFF
    -DLLVM_ENABLE_Z3_SOLVER=OFF
    -DLLVM_ENABLE_BINDINGS=OFF'
"

# Collect a PGO profile from instrumented clang and lld. The host clang
# instruments them and links its own profile runtime, so its `llvm-profdata`
# reads what they write. Delete `clang.profdata` to collect it again.
if [[ ! -f ${build}/clang.profdata ]]; then
  in_manylinux "
    ${llvm_options}
    cmake -S /src/llvm -B /build/obj-instrumented -G Ninja \${llvm_options} \
      -DLLVM_ENABLE_PROJECTS='clang;lld' \
      -DLLVM_BUILD_INSTRUMENTED=IR \
      -DLLVM_BUILD_RUNTIME=OFF \
      -DLLVM_PARALLEL_COMPILE_JOBS=8 \
      -DLLVM_PARALLEL_LINK_JOBS=2
    ninja -C /build/obj-instrumented clang lld
  "
  rm -rf "${build}/profiles"
  train "${build}/obj-instrumented/bin:${host_llvm}/bin" "env LLVM_PROFILE_FILE='${build}/profiles/%4m.profraw'"
  "${host_llvm}/bin/llvm-profdata" merge -o "${build}/clang.profdata" "${build}/profiles"
  rm -rf "${build}/profiles"
fi

in_manylinux "
  # The just-built clang compiles compiler-rt; aim it at gcc-toolset's
  # libstdc++ too. This config is not installed.
  mkdir -p /build/obj/bin
  echo --gcc-install-dir=\${gcc_install_dir} > /build/obj/bin/x86_64-unknown-linux-gnu.cfg

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
  # installed unstripped, and stripped after BOLT runs. Full LTO makes both
  # compiling and linking need much more memory, so fewer of them run at once.
  ${llvm_options}
  cmake -S /src/llvm -B /build/obj -G Ninja \${llvm_options} \
    -DCMAKE_INSTALL_PREFIX=/build/${name} \
    -DCMAKE_EXE_LINKER_FLAGS=-Wl,-q \
    -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-q \
    -DLLVM_ENABLE_PROJECTS='bolt;clang;clang-tools-extra;lld' \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_ENABLE_LTO=Full \
    -DLLVM_PROFDATA_FILE=/build/clang.profdata \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DCLANG_LINK_CLANG_DYLIB=ON \
    -DLLVM_PARALLEL_COMPILE_JOBS=4 \
    -DLLVM_PARALLEL_LINK_JOBS=1 \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
    -DLLVM_ENABLE_LIBXML2=FORCE_ON \
    -DLIBXML2_INCLUDE_DIR=/build/libxml2/include/libxml2 \
    -DLIBXML2_LIBRARY=/build/libxml2/lib/libxml2.a
  rm -rf /build/${name}
  ninja -C /build/obj install
  rm -rf /build/${name}/include /build/${name}/lib/cmake /build/${name}/share/man
  find /build/${name}/lib -maxdepth 1 -name '*.a' ! -name 'libbolt_rt_*' -delete

  # compiler-rt for Windows: builtins (such as 128-bit division), sanitizers,
  # libFuzzer, and profiling.
  unset CFLAGS CXXFLAGS
  bin=/build/${name}/bin
  include='/imsvc/build/xwin/crt/include /imsvc/build/xwin/sdk/include/ucrt /imsvc/build/xwin/sdk/include/um /imsvc/build/xwin/sdk/include/shared'
  libpath='/libpath:/build/xwin/crt/lib/x86_64 /libpath:/build/xwin/sdk/lib/um/x86_64 /libpath:/build/xwin/sdk/lib/ucrt/x86_64'
  rm -rf /build/obj-windows
  cmake -S /src/runtimes -B /build/obj-windows -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TRY_COMPILE_CONFIGURATION=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=AMD64 \
    -DCMAKE_C_COMPILER=\${bin}/clang-cl \
    -DCMAKE_CXX_COMPILER=\${bin}/clang-cl \
    -DCMAKE_C_COMPILER_TARGET=x86_64-pc-windows-msvc \
    -DCMAKE_CXX_COMPILER_TARGET=x86_64-pc-windows-msvc \
    -DCMAKE_LINKER=\${bin}/lld-link \
    -DCMAKE_AR=\${bin}/llvm-lib \
    -DCMAKE_RC_COMPILER=\${bin}/llvm-rc \
    -DCMAKE_MT=\${bin}/llvm-mt \
    -DCMAKE_ASM_MASM_COMPILER=\${bin}/llvm-ml \
    \"-DCMAKE_C_FLAGS=\${include}\" \
    \"-DCMAKE_CXX_FLAGS=\${include}\" \
    \"-DCMAKE_EXE_LINKER_FLAGS=\${libpath}\" \
    \"-DCMAKE_SHARED_LINKER_FLAGS=\${libpath}\" \
    \"-DCMAKE_MODULE_LINKER_FLAGS=\${libpath}\" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_INCLUDE_TESTS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_INSTALL_PATH=\$(\${bin}/clang -print-resource-dir)
  ninja -C /build/obj-windows install

  # The MSVC driver links compiler-rt only when asked to, and \`link.exe\`
  # never exists on Linux.
  printf -- '--rtlib=compiler-rt\\n-fuse-ld=lld\\n' > \${bin}/x86_64-pc-windows-msvc.cfg
"

# Clang and lld spend nearly all of their time in these.
train "${toolchain}/bin" "perf record -F 1000 -e cycles:u -j any,u -o '${build}/perf.data' --"
for binary in "${toolchain}"/lib/libLLVM.so.*git "${toolchain}"/lib/libclang-cpp.so.*git "${toolchain}/bin/lld"; do
  "${toolchain}/bin/perf2bolt" "${binary}" -p "${build}/perf.data" -o "${binary}.fdata"
  "${toolchain}/bin/llvm-bolt" "${binary}" -o "${binary}.bolt" -data "${binary}.fdata" \
    -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions \
    -split-all-cold -split-eh -dyno-stats -icf=1 -use-gnu-stack
  mv "${binary}.bolt" "${binary}"
  rm "${binary}.fdata"
done
rm -rf "${build}/perf.data" "${train}" "${build}/libcat"

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
    --notes "Portable Linux x86-64 toolchain from \`lilian\` at ${revision} (GlibC 2.28+). It is compiled by clang with full LTO and PGO, and optimized with BOLT, from profiles of building libCat. Includes clang-cl, lld-link, llvm-mt, llvm-lib, llvm-rc, and compiler-rt (builtins, sanitizers, libFuzzer, profiling) for cross-compiling to Windows, and llvm-bolt, perf2bolt, and merge-fdata." \
    "${build}/${name}.tar.zst" "${build}/${name}.tar.zst.sha256"
fi
