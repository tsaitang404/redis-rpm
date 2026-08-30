#!/bin/bash
set -ex
VERSION="${REDIS_VERSION:?REDIS_VERSION not set}"
MAJOR=$(echo "$VERSION" | cut -d. -f1)
ARCH=$(uname -m)
# Normalize arch name for RPM
case "$ARCH" in
  x86_64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac
export ARCH

cd /tmp
if [ "$VERSION" = "unstable" ]; then
  git clone --depth 1 https://github.com/redis/redis.git redis-"$VERSION" 2>&1 | tail -3
  cd redis-"$VERSION"
  yq -i '.modules[].ref = "master"' modules/modules.yaml
else
  curl -sL "https://github.com/redis/redis/archive/refs/tags/${VERSION}.tar.gz" -o redis.tar.gz
  rm -rf redis-"$VERSION" && tar xzf redis.tar.gz && cd redis-"$VERSION"
fi

# Install prerequisites
dnf install -y --allowerasing make gcc gcc-c++ rpm-build curl wget git tar gzip findutils openssl-devel systemd-devel cmake 2>&1 | tail -3 || true
command -v rpmbuild || dnf install -y rpm-build || true

# LLVM 21 for RediSearch (required exactly clang-21/lld-21)
if ! command -v clang-21 &>/dev/null; then
  if [ -f /etc/fedora-release ]; then :; fi
  # Try distro LLVM 21 first, else official llvm.org repo
  dnf install -y llvm-toolset-21 2>/dev/null || true
  if ! command -v clang-21 &>/dev/null; then
    dnf install -y 'dnf-command(config-manager)' 2>/dev/null || true
    dnf config-manager --set-enabled crb 2>/dev/null || true
    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest.rpm 2>/dev/null ||       dnf install -y epel-release 2>/dev/null || true
    dnf install -y clang21 lld21 2>/dev/null || true
  fi
  if ! command -v clang-21 &>/dev/null; then
    # Official LLVM repo (works on el8/9/10)
    MAJOR_NUM=$(rpm -E %{rhel})
    dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${MAJOR_NUM}.noarch.rpm" 2>/dev/null || true
    dnf config-manager --add-repo "https://apt.llvm.org/llvm-rhel${MAJOR_NUM}.repo" 2>/dev/null || true
    dnf config-manager --set-enabled llvm-21 2>/dev/null || true
    dnf install -y clang-tools-extra-21 clang-21 lld-21 2>/dev/null ||       dnf --enablerepo=llvm-21 install -y clang-21 lld-21 2>/dev/null || true
  fi
fi
# Ensure ld.lld + llvm-ar are available for clang-21 LTO
# On el9, llvm.org repo may not have lld-21; install explicitly
if ! command -v ld.lld &>/dev/null && ! command -v ld.lld-21 &>/dev/null; then
  dnf --enablerepo=llvm-21 install -y lld-21 2>/dev/null || true
  if ! command -v ld.lld &>/dev/null; then
    dnf install -y lld 2>/dev/null || true
  fi
fi
# Find ld.lld in all known paths
LLD_FOUND=0
for candidate in /opt/llvm/bin/ld.lld /usr/bin/ld.lld /usr/local/bin/ld.lld; do
  if [ -x "$candidate" ]; then
    [ ! -x /usr/bin/ld.lld ] && ln -sf "$candidate" /usr/bin/ld.lld
    [ ! -x /usr/bin/ld.lld-21 ] && ln -sf "$candidate" /usr/bin/ld.lld-21
    LLD_FOUND=1
    break
  fi
done
if [ "$LLD_FOUND" -eq 0 ]; then
  for candidate in $(find /usr -name "ld.lld*" 2>/dev/null | head -3); do
    [ ! -x /usr/bin/ld.lld ] && ln -sf "$candidate" /usr/bin/ld.lld
    [ ! -x /usr/bin/ld.lld-21 ] && ln -sf "$candidate" /usr/bin/ld.lld-21
    LLD_FOUND=1
    break
  done
fi
# Ensure llvm-ar-21 exists (needed for LTO static library creation with clang-21)
if ! command -v llvm-ar-21 &>/dev/null; then
  # Install llvm package which provides llvm-ar-21
  dnf install -y llvm 2>/dev/null || true
  # Also try llvm-21 from llvm.org
  dnf --enablerepo=llvm-21 install -y llvm-21 2>/dev/null || true
fi
# Find llvm-ar-21 in all known paths
for candidate in /opt/llvm/bin/llvm-ar-21 /usr/bin/llvm-ar-21 /usr/local/bin/llvm-ar-21; do
  if [ -x "$candidate" ]; then
    [ ! -x /usr/bin/llvm-ar-21 ] && ln -sf "$candidate" /usr/bin/llvm-ar-21
    break
  fi
done
# Also create llvm-ranlib-21 if needed
if ! command -v llvm-ranlib-21 &>/dev/null && command -v llvm-ar-21 &>/dev/null; then
  ln -sf "$(command -v llvm-ar-21)" /usr/bin/llvm-ranlib-21 2>/dev/null || true
fi
command -v ld.lld &>/dev/null && echo "ld.lld: $(command -v ld.lld)" || echo "WARNING: ld.lld not found"
command -v llvm-ar-21 &>/dev/null && echo "llvm-ar-21: $(command -v llvm-ar-21)" || echo "WARNING: llvm-ar-21 not found"
command -v llvm-ranlib-21 &>/dev/null && echo "llvm-ranlib-21: $(command -v llvm-ranlib-21)" || echo "WARNING: llvm-ranlib-21 not found"
# Redis core stays on gcc; RediSearch CMake/Rust finds clang-21 via PATH
if [ -x /opt/llvm-21.1.8/bin/clang ]; then export PATH="/opt/llvm-21.1.8/bin:$PATH"; fi
# Don't export CC/CXX globally — breaks core jemalloc with GNU ld

# Rust for RedisJSON
if ! command -v rustc &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable 2>&1 | tail -3
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# GCC toolset
for ts in 15 14 13; do
  [ -f "/etc/profile.d/gcc-toolset-${ts}.sh" ] && source "/etc/profile.d/gcc-toolset-${ts}.sh" && break
done 2>/dev/null || true

# Build
# On el8, pkg-config may not find OpenSSL correctly
export BUILD_TLS=yes USE_SYSTEMD=yes
if command -v pkg-config &>/dev/null && pkg-config --exists openssl 2>/dev/null; then
  export TLS_CFLAGS="$(pkg-config --cflags openssl)"
  export TLS_LDFLAGS="$(pkg-config --libs openssl)"
  echo "TLS via pkg-config: CFLAGS=$TLS_CFLAGS LDFLAGS=$TLS_LDFLAGS"
else
  # Fallback: check common OpenSSL locations
  for ssl_dir in /usr /usr/local; do
    if [ -f "$ssl_dir/include/openssl/ssl.h" ]; then
      export OPENSSL_PREFIX="$ssl_dir"
      export TLS_CFLAGS="-I$ssl_dir/include"
      export TLS_LDFLAGS="-L$ssl_dir/lib64 -lssl -lcrypto"
      echo "TLS fallback: OPENSSL_PREFIX=$OPENSSL_PREFIX"
      break
    fi
  done
fi
if command -v clang &>/dev/null; then export LTO=1; else export LTO=0; fi

# Install ARM cross-compiler toolchain for aarch64 builds
if [ "$ARCH" = "aarch64" ]; then
  echo "=== Setting up aarch64 cross-compilation ==="
  BUILD_MODULES=false  # modules need native build
  TOOLCHAIN_DIR="/opt/arm-toolchain"
  if [ ! -d "$TOOLCHAIN_DIR" ]; then
    echo "Downloading ARM GNU Toolchain..."
    TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-x86_64-aarch64-none-linux-gnu.tar.xz"
    curl -sL "$TOOLCHAIN_URL" | tar xJ -C /opt/
    mv /opt/arm-gnu-toolchain-* "$TOOLCHAIN_DIR" 2>/dev/null || true
  fi
  export CC="$TOOLCHAIN_DIR/bin/aarch64-none-linux-gnu-gcc"
  export CXX="$TOOLCHAIN_DIR/bin/aarch64-none-linux-gnu-g++"
  export AR="$TOOLCHAIN_DIR/bin/aarch64-none-linux-gnu-ar"
  export RANLIB="$TOOLCHAIN_DIR/bin/aarch64-none-linux-gnu-ranlib"
  export STRIP="$TOOLCHAIN_DIR/bin/aarch64-none-linux-gnu-strip"
  echo "Using cross-compiler: $CC"
  $CC --version | head -1
fi

# BUILD_MODULES=false to skip module compilation (core-only build)
if [ "${BUILD_MODULES}" != "false" ] && [ "$MAJOR" -ge 8 ] && [ -f modules/modules.yaml ]; then
  make modules-update MODULES_UPDATE_SHALLOW=1 2>&1 | tail -5
  make -C modules install-rust INSTALL_RUST_TOOLCHAIN=yes 2>&1 | tail -5 || true
  make build -j"$(nproc)" 2>&1 || make -C src all -j"$(nproc)"
else
  make -j"$(nproc)"
fi

# Stage files
DESTDIR=/tmp/staging
mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/lib/redis/modules" "$DESTDIR/etc/redis/sentinel" \
  "$DESTDIR/var/lib/redis" "$DESTDIR/var/log/redis" "$DESTDIR/run/redis" "$DESTDIR/run/sentinel" \
  "$DESTDIR/usr/lib/systemd/system" "$DESTDIR/usr/share/selinux/packages"

for bin in redis-server redis-cli redis-benchmark redis-check-rdb redis-check-aof; do
  [ -f src/$bin ] && install -m 755 src/$bin "$DESTDIR/usr/bin/"
done
ln -sf redis-server "$DESTDIR/usr/bin/redis-sentinel"
cp redis.conf "$DESTDIR/etc/redis/" 2>/dev/null || true
cp sentinel.conf "$DESTDIR/etc/redis/sentinel/" 2>/dev/null || true
[ -f utils/systemd-redis_server.service ] && install -m 644 utils/systemd-redis_server.service "$DESTDIR/usr/lib/systemd/system/redis.service"
if [ -f utils/systemd-redis_sentinel.service ]; then install -m 644 utils/systemd-redis_sentinel.service "$DESTDIR/usr/lib/systemd/system/redis-sentinel.service"; else install -m 644 utils/systemd-redis_server.service "$DESTDIR/usr/lib/systemd/system/redis-sentinel.service"; sed -i "s/redis-server \/etc\/redis\/redis.conf/redis-server \/etc\/redis\/sentinel\/sentinel.conf --sentinel/" "$DESTDIR/usr/lib/systemd/system/redis-sentinel.service"; fi

# Modules
if [ "$MAJOR" -ge 8 ]; then
  for mod_dir in modules/*/; do
    [ -d "$mod_dir" ] || continue
    mod_name=$(basename "$mod_dir")
    so_file=$(find "$mod_dir" -maxdepth 3 -name "*.so" ! -name "lib*" -print -quit 2>/dev/null)
    if [ -n "$so_file" ]; then
      cp "$so_file" "$DESTDIR/usr/lib/redis/modules/${mod_name}.so"
      echo "  module: ${mod_name}.so"
    fi
  done
fi

[ -d selinux ] && cp selinux/* "$DESTDIR/usr/share/selinux/packages/" 2>/dev/null || true

# Verify
echo "=== Staged binaries ==="
ls "$DESTDIR/usr/bin/"
echo "=== Staged modules ==="
ls "$DESTDIR/usr/lib/redis/modules/"
echo "=== Done ==="
