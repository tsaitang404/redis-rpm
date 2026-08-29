#!/bin/bash
set -ex
VERSION="${REDIS_VERSION:?REDIS_VERSION not set}"
MAJOR=$(echo "$VERSION" | cut -d. -f1)

# --- fetch source ---
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
# Basic build tools + rpmbuild
dnf install -y --allowerasing make gcc gcc-c++ rpm-build curl wget git tar gzip findutils openssl-devel systemd-devel || true

# GCC toolset (el8/9)
for ts in 15 14 13; do
  [ -f "/etc/profile.d/gcc-toolset-${ts}.sh" ] && source "/etc/profile.d/gcc-toolset-${ts}.sh" && break
done 2>/dev/null || true

# LLVM/Clang + lld for RediSearch
if [ -x /opt/llvm/bin/clang ]; then
  export PATH="/opt/llvm/bin:$PATH"
elif [ -x /opt/llvm-21.1.8/bin/clang ]; then
  export PATH="/opt/llvm-21.1.8/bin:$PATH"
fi
command -v lld-21 2>/dev/null || command -v lld 2>/dev/null || (dnf install -y lld || true)

export BUILD_TLS=yes USE_SYSTEMD=yes
# LTO only when LLVM available
if command -v clang &>/dev/null; then export LTO=1; else export LTO=0; fi

# --- Build (official flow: modules-update -> install-rust -> deploy) ---
if [ "$MAJOR" -ge 8 ] && [ -f modules/modules.yaml ]; then
  make modules-update MODULES_UPDATE_SHALLOW=1 2>&1 | tail -5
  make -C modules install-rust INSTALL_RUST_TOOLCHAIN=yes 2>&1 | tail -5
  make -j"$(nproc)" deploy PREFIX=/usr/local 2>&1 || make -j"$(nproc)" deploy PREFIX=/usr/local || true
  echo "=== Modules installed ==="
  ls -la /usr/local/lib/redis/modules/ 2>/dev/null || true
else
  make -j"$(nproc)" all 2>&1 | tail -3
  make install PREFIX=/usr/local 2>&1 | tail -3
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
MAJOR=$(echo "%{version}" | cut -d. -f1)
if [ "$MAJOR" -ge 8 ] && [ -f modules/modules.yaml ]; then
  for ts in 15 14 13; do
    [ -f "/etc/profile.d/gcc-toolset-${ts}.sh" ] && source "/etc/profile.d/gcc-toolset-${ts}.sh" && break
  done 2>/dev/null || true
  [ -x /opt/llvm/bin/clang ] && export PATH="/opt/llvm/bin:$PATH"
  [ -x /opt/llvm-21.1.8/bin/clang ] && export PATH="/opt/llvm-21.1.8/bin:$PATH"
  command -v lld-21 2>/dev/null || command -v lld 2>/dev/null || (dnf install -y lld || true)
  # Install LLVM if missing (for RediSearch)
  if ! command -v clang-21 &>/dev/null && ! command -v clang &>/dev/null; then
    dnf install -y -q clang lld 2>&1 | tail -1 || true
  fi
  if [ -x /opt/llvm-21.1.8/bin/clang ]; then export PATH="/opt/llvm-21.1.8/bin:$PATH"; fi
  export BUILD_TLS=yes USE_SYSTEMD=yes
  if command -v clang &>/dev/null; then export LTO=1; else export LTO=0; fi
  make modules-update MODULES_UPDATE_SHALLOW=1 2>&1 | tail -5
  make -C modules install-rust INSTALL_RUST_TOOLCHAIN=yes 2>&1 | tail -5
  make -j\$(nproc) deploy PREFIX=/usr/local 2>&1 || true
else
  make -j\$(nproc)
fi
%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/{usr/bin,etc/redis/sentinel,var/lib/redis,var/log/redis,run/redis,run/sentinel,usr/lib/redis/modules,usr/lib/systemd/system,usr/share/selinux/packages}
install -m 755 src/redis-server %{buildroot}/usr/bin/
install -m 755 src/redis-cli %{buildroot}/usr/bin/
install -m 755 src/redis-benchmark %{buildroot}/usr/bin/
install -m 755 src/redis-check-rdb %{buildroot}/usr/bin/
install -m 755 src/redis-check-aof %{buildroot}/usr/bin/
ln -sf redis-server %{buildroot}/usr/bin/redis-sentinel
ln -sf redis-server %{buildroot}/usr/bin/redis-check-aof
cp redis.conf %{buildroot}/etc/redis/
cp sentinel.conf %{buildroot}/etc/redis/sentinel/
install -m 644 -D src/systemd-redis_server.service %{buildroot}/usr/lib/systemd/system/redis.service
install -m 644 -D src/systemd-redis_sentinel.service %{buildroot}/usr/lib/systemd/system/redis-sentinel.service
# Install modules from make deploy output
if [ -d /usr/local/lib/redis/modules ]; then
  cp -a /usr/local/lib/redis/modules/*.so %{buildroot}/usr/lib/redis/modules/ 2>/dev/null || true
fi
# Also check build tree for modules
find . -path "*/bin/*release*" -name "*.so" ! -path "./src/*" ! -name "lib*" -exec cp {} %{buildroot}/usr/lib/redis/modules/ \; 2>/dev/null || true
# Install SELinux
[ -d selinux ] && cp selinux/* %{buildroot}/usr/share/selinux/packages/ 2>/dev/null || true
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
rpmbuild -bb --noclean "$SPEC_FILE"
cp ~/rpmbuild/RPMS/x86_64/*.rpm /out/ 2>/dev/null || cp ~/rpmbuild/RPMS/*/*.rpm /out/ 2>/dev/null
echo "=== Done ==="
