#!/bin/bash
set -ex
VERSION="${REDIS_VERSION:?REDIS_VERSION not set}"
MAJOR=$(echo "$VERSION" | cut -d. -f1)

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

# LLVM for RediSearch
if [ -x /opt/llvm-21.1.8/bin/clang ]; then export PATH="/opt/llvm-21.1.8/bin:$PATH"; fi
command -v lld-21 2>/dev/null || command -v lld 2>/dev/null || (dnf install -y lld || true)

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
export BUILD_TLS=yes USE_SYSTEMD=yes
if command -v clang &>/dev/null; then export LTO=1; else export LTO=0; fi

if [ "$MAJOR" -ge 8 ] && [ -f modules/modules.yaml ]; then
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
[ -f src/systemd-redis_server.service ] && install -m 644 src/systemd-redis_server.service "$DESTDIR/usr/lib/systemd/system/redis.service"
[ -f src/systemd-redis_sentinel.service ] && install -m 644 src/systemd-redis_sentinel.service "$DESTDIR/usr/lib/systemd/system/redis-sentinel.service"

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
