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

# --- Install prerequisites ---
command -v rpmbuild || dnf install -y rpm-build || true
command -v lld-21 2>/dev/null || command -v lld 2>/dev/null || (dnf install -y lld || true)

# LLVM for RediSearch
if [ -x /opt/llvm-21.1.8/bin/clang ]; then
  export PATH="/opt/llvm-21.1.8/bin:$PATH"
elif [ -x /opt/llvm/bin/clang ]; then
  export PATH="/opt/llvm/bin:$PATH"
fi

# Rust for RedisJSON
if ! command -v rustc &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable 2>&1 | tail -3
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# --- Build (official flow) ---
if [ "$MAJOR" -ge 8 ] && [ -f modules/modules.yaml ]; then
  export BUILD_TLS=yes USE_SYSTEMD=yes
  if command -v clang &>/dev/null; then export LTO=1; else export LTO=0; fi
  make modules-update MODULES_UPDATE_SHALLOW=1 2>&1 | tail -5
  make -C modules install-rust INSTALL_RUST_TOOLCHAIN=yes 2>&1 | tail -5 || true
  make build -j"$(nproc)" 2>&1 || make -C src all -j"$(nproc)"
  make -j"$(nproc)" deploy PREFIX=/usr/local 2>&1 || make deploy PREFIX=/usr/local || true
else
  make -j"$(nproc)"
fi

# --- rpmbuild ---
SPEC_FILE="/tmp/redis.spec"
mkdir -p ~/rpmbuild/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}
tar czf ~/rpmbuild/SOURCES/redis-${VERSION}.tar.gz -C /tmp "redis-${VERSION}"

cat > "$SPEC_FILE" << SPEC
Name:             redis
Version:          REPLACE_VERSION
Release:          1
Summary:          Redis (persistent key-value database with modules)
License:          SSPLv1 and RSALv2 and BSD
URL:              https://redis.io
Source0:          redis-%{version}.tar.gz
Requires(pre):    shadow-utils
Requires(post):   systemd
Requires(preun):  systemd
Requires(postun): systemd
BuildRequires:    systemd systemd-devel
%define debug_package %{nil}
%global _enable_debug_package 0
%global __os_install_post %{nil}
%description
Redis %{version} with bundled modules.
%prep
%setup -q
%build
echo "Build already completed outside rpmbuild, skipping."
%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/{usr/bin,etc/redis/sentinel,var/lib/redis,var/log/redis,run/redis,run/sentinel,usr/lib/redis/modules,usr/lib/systemd/system,usr/share/selinux/packages}
# Binaries from make deploy
for bin in redis-server redis-cli redis-benchmark redis-check-rdb redis-check-aof; do
  install -m 755 /usr/local/bin/$bin %{buildroot}/usr/bin/ 2>/dev/null || true
done
ln -sf redis-server %{buildroot}/usr/bin/redis-sentinel
# Config
cp /usr/local/etc/redis/redis.conf %{buildroot}/etc/redis/ 2>/dev/null || cp redis.conf %{buildroot}/etc/redis/ 2>/dev/null || true
cp /usr/local/etc/redis/sentinel.conf %{buildroot}/etc/redis/sentinel/ 2>/dev/null || cp sentinel.conf %{buildroot}/etc/redis/sentinel/ 2>/dev/null || true
# Systemd
[ -f src/systemd-redis_server.service ] && install -m 644 -D src/systemd-redis_server.service %{buildroot}/usr/lib/systemd/system/redis.service
[ -f src/systemd-redis_sentinel.service ] && install -m 644 -D src/systemd-redis_sentinel.service %{buildroot}/usr/lib/systemd/system/redis-sentinel.service
# Modules from make deploy — only copy actual module .so files, not Rust proc-macro libs
if [ -d /usr/local/lib/redis/modules ]; then
  for so in /usr/local/lib/redis/modules/*.so; do
    [ -f "$so" ] || continue
    name=$(basename "$so")
    # Skip lib* (Rust proc-macro/derive crates) and libevent* (system libs)
    case "$name" in lib*|libevent*) continue ;; esac
    cp "$so" %{buildroot}/usr/lib/redis/modules/
  done
fi
# SELinux
[ -d selinux ] && cp selinux/* %{buildroot}/usr/share/selinux/packages/ 2>/dev/null || true
echo "=== Modules in buildroot ==="
ls -la %{buildroot}/usr/lib/redis/modules/ 2>/dev/null || true
%files
%dir %attr(0750,redis,redis) /var/lib/redis
%dir %attr(0750,redis,redis) /var/log/redis
%dir %attr(0755,redis,redis) /run/redis
%dir %attr(0755,redis,redis) /run/sentinel
/usr/bin/redis-server
/usr/bin/redis-cli
/usr/bin/redis-benchmark
/usr/bin/redis-check-rdb
/usr/bin/redis-check-aof
/usr/bin/redis-sentinel
/usr/lib/redis/modules/
/usr/lib/systemd/system/redis.service
/usr/lib/systemd/system/redis-sentinel.service
%config(noreplace) /etc/redis/redis.conf
%config(noreplace) /etc/redis/sentinel/
/usr/share/selinux/packages/
%pre
getent group redis &>/dev/null || groupadd -r redis
getent passwd redis &>/dev/null || useradd -r -g redis -d /var/lib/redis -s /sbin/nologin redis
%post
systemctl daemon-reload
%preun
if [ \$1 -eq 0 ]; then
  systemctl stop redis.service redis-sentinel.service 2>/dev/null || true
  systemctl disable redis.service redis-sentinel.service 2>/dev/null || true
fi
%postun
if [ \$1 -ge 1 ]; then
  systemctl try-restart redis.service redis-sentinel.service 2>/dev/null || true
fi
SPEC

sed -i "s/REPLACE_VERSION/${VERSION}/" "$SPEC_FILE"
rpmbuild -bb --noclean "$SPEC_FILE" 2>&1 | tail -5
cp ~/rpmbuild/RPMS/x86_64/*.rpm /out/ 2>/dev/null || cp ~/rpmbuild/RPMS/*/*.rpm /out/ 2>/dev/null
echo "=== Done ==="
