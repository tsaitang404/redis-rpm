#!/usr/bin/env bash
# Install LLVM 21 for RediSearch's cross-language (C/Rust) LTO build.
# LLVM has no dnf repo, so we use the official upstream tarball.
#
# Rocky 10 only: prebuilt LLVM 21 binaries need GLIBCXX_3.4.30+; Rocky 10
# ships it (3.4.32). Rocky 8/9 don't — gcc-toolset ships compile-time headers
# only, no newer libstdc++.so.6 runtime, so there is nothing to vendor.

set -euo pipefail

LLVM_VERSION="${LLVM_VERSION:-21.1.8}"
MAJOR="${LLVM_VERSION%%.*}"

case "$(uname -m)" in
	x86_64)  asset="LLVM-${LLVM_VERSION}-Linux-X64.tar.xz" ;;
	aarch64) asset="LLVM-${LLVM_VERSION}-Linux-ARM64.tar.xz" ;;
	*) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

install_root="/opt/llvm-${LLVM_VERSION}"
mkdir -p "$install_root"
curl -fsSL "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${asset}" \
	| tar -xJ -C "$install_root" --strip-components=1
ln -sfn "$install_root" /opt/llvm

# RediSearch's build scripts look up clang-${MAJOR}, lld-${MAJOR}, etc. on PATH;
# the upstream tarball ships unsuffixed names only, so alias them.
for tool in clang clang++ clang-cpp lld ld.lld ld64.lld lld-link llc opt \
            llvm-ar llvm-nm llvm-ranlib llvm-strip llvm-objcopy llvm-objdump \
            llvm-readelf llvm-config; do
	src="/opt/llvm/bin/${tool}"
	dst="/opt/llvm/bin/${tool}-${MAJOR}"
	[ -e "$src" ] && [ ! -e "$dst" ] && ln -sfn "$src" "$dst"
done

echo 'export PATH=/opt/llvm/bin:$PATH' > /etc/profile.d/llvm.sh

/opt/llvm/bin/clang-${MAJOR} --version
/opt/llvm/bin/ld.lld-${MAJOR} --version
