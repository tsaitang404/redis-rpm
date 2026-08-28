#!/bin/bash
# Build one Redis RPM inside a Rocky Linux container (aligned with official redis-rpm).
# Env: REDIS_VERSION (e.g. 8.10.1)
set -ex

VERSION="${REDIS_VERSION:?REDIS_VERSION not set}"
ARCH=$(uname -m)
MAJOR=$(echo "$VERSION" | cut -d. -f1)

# --- dependencies (match official Dockerfile) --------------------------------
dnf install -y -q gcc gcc-c++ make cmake wget tar gzip rpm-build \
  python3 python3-pip openssl-devel which git unzip curl \
  libtool automake autoconf jq systemd-devel 2>&1 | tail -1

# el8: enable PowerTools + EPEL + gcc-toolset-13
if [ "$MAJOR" -ge 8 ]; then
  dnf install -y -q epel-release 2>&1 | tail -1
  dnf config-manager --set-enabled powertools 2>/dev/null || \
  dnf config-manager --set-enabled crb 2>/dev/null || true
  if dnf list -q gcc-toolset-13-gcc 2>/dev/null | grep -q gcc-toolset; then
    dnf install -y -q gcc-toolset-13-gcc gcc-toolset-13-gcc-c++ 2>&1 | tail -1
    source /opt/rh/gcc-toolset-13/enable 2>/dev/null || true
    export PATH="/opt/rh/gcc-toolset-13/root/usr/bin:$PATH"
  fi
  # Rust toolchain for RedisJSON
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tail -3
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# --- fetch source ------------------------------------------------------------
cd /tmp
wget -q "https://download.redis.io/releases/redis-${VERSION}.tar.gz"
tar xzf "redis-${VERSION}.tar.gz"
cd "redis-${VERSION}"

mkdir -p /workspace/dist
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
tar czf ~/rpmbuild/SOURCES/redis-${VERSION}.tar.gz -C /tmp redis-${VERSION}

# --- build command -----------------------------------------------------------
if [ "$MAJOR" -ge 8 ]; then
  # Install module dependencies first
  make bootstrap 2>&1 | tail -5 || true
  BUILD_CMD='make build -j$(nproc)'
else
  BUILD_CMD='make -j$(nproc)'
fi

cat > ~/rpmbuild/SPECS/redis.spec <<'SPECEOF'
%define debug_package %{nil}
Name:           redis
Version:        REPLACE_VERSION
Release:        1%{?dist}
Summary:        Redis in-memory key-value database
License:        BSD-3-Clause (<=7.2), RSALv2/SSPLv1 (7.4-7.8), RSALv2/SSPLv1/AGPLv3 (>=8.0)
URL:            https://redis.io
Source0:        redis-REPLACE_VERSION.tar.gz
BuildRequires:  gcc, gcc-c++, make, cmake, python3, openssl-devel, rust

%description
Redis is an in-memory data structure store used as database, cache and message
broker. Auto-built from tsaitang404/redis-rpm pipeline, aligned with official
redis/redis-rpm packaging.

%prep
%setup -q

%build
REPLACE_BUILD_CMD

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}{/usr/bin,/etc/redis/sentinel,/var/lib/redis,/var/log/redis,/run/redis,/run/sentinel,/usr/lib/redis/modules,/usr/lib/systemd/system,/usr/share/selinux/packages}

# Binaries
install -m 755 src/redis-server     %{buildroot}/usr/bin/
install -m 755 src/redis-cli        %{buildroot}/usr/bin/
install -m 755 src/redis-benchmark  %{buildroot}/usr/bin/
install -m 755 src/redis-check-aof  %{buildroot}/usr/bin/
install -m 755 src/redis-check-rdb  %{buildroot}/usr/bin/
ln -s redis-server %{buildroot}/usr/bin/redis-sentinel

# Modules (8.x only)
if ls bin/linux-*-release/*.so >/dev/null 2>&1; then
  install -m 755 bin/linux-*-release/*.so %{buildroot}/usr/lib/redis/modules/
fi
# RediSearch puts its .so in a subdirectory
if ls bin/linux-*-release/search-community/*.so >/dev/null 2>&1; then
  install -m 755 bin/linux-*-release/search-community/*.so %{buildroot}/usr/lib/redis/modules/
fi

# Config files
install -m 640 redis.conf    %{buildroot}/etc/redis/redis.conf
install -m 640 sentinel.conf %{buildroot}/etc/redis/sentinel/sentinel.conf

# redis.service (matches official)
cat > %{buildroot}/usr/lib/systemd/system/redis.service <<'SVCEOF'
[Unit]
Description=Advanced key-value store
After=network.target
Documentation=http://redis.io/documentation

[Service]
Type=notify
ExecStart=/usr/bin/redis-server /etc/redis/redis.conf
TimeoutStopSec=0
Restart=always
User=redis
Group=redis
RuntimeDirectory=redis
RuntimeDirectoryMode=2755

UMask=007
PrivateTmp=yes
LimitNOFILE=65535
PrivateDevices=yes
ProtectHome=yes
ReadOnlyDirectories=/
ReadWriteDirectories=-/var/lib/redis
ReadWriteDirectories=-/var/log/redis
ReadWriteDirectories=-/run/redis

NoNewPrivileges=true
CapabilityBoundingSet=CAP_SYS_RESOURCE
ProtectSystem=true
ReadWriteDirectories=-/etc/redis

[Install]
WantedBy=multi-user.target
Alias=redis.service
SVCEOF

# redis-sentinel.service (matches official)
cat > %{buildroot}/usr/lib/systemd/system/redis-sentinel.service <<'SVCEOF'
[Unit]
Description=Advanced key-value store
After=network.target
Documentation=http://redis.io/documentation

[Service]
Type=notify
ExecStart=/usr/bin/redis-sentinel /etc/redis/sentinel/sentinel.conf
TimeoutStopSec=0
Restart=always
User=redis
Group=redis
RuntimeDirectory=sentinel
RuntimeDirectoryMode=2755

UMask=007
PrivateTmp=yes
LimitNOFILE=65535
PrivateDevices=yes
ProtectHome=yes
ReadOnlyDirectories=/
ReadWriteDirectories=-/var/lib/redis
ReadWriteDirectories=-/var/log/redis
ReadWriteDirectories=-/run/sentinel

NoNewPrivileges=true
CapabilityBoundingSet=CAP_SYS_RESOURCE
ProtectSystem=true
ReadWriteDirectories=-/etc/redis

[Install]
WantedBy=multi-user.target
Alias=redis-sentinel.service
SVCEOF

# SELinux policy
cat > %{buildroot}/usr/share/selinux/packages/redis-ce.te <<'SEPOL'
module redis-ce 1.0;

require {
    type redis_t;
    type redis_conf_t;
    type redis_port_t;
    class tcp_socket name_connect;
    class file { read write open };
}

allow redis_t redis_conf_t:file { read write open };
SEPOL

cat > %{buildroot}/usr/share/selinux/packages/redis-ce.fc <<'SEFC'
/etc/redis(/.*)?    gen_context(system_u:object_r:redis_conf_t,s0)
/run/redis(/.*)?    gen_context(system_u:object_r:redis_var_run_t,s0)
SEFC

%pre
getent group redis  >/dev/null || groupadd -r redis
getent passwd redis >/dev/null || useradd -r -g redis -d /var/lib/redis -s /sbin/nologin redis

%post
if command -v checkmodule &>/dev/null && command -v semodule_package &>/dev/null; then
    checkmodule -M -m /usr/share/selinux/packages/redis-ce.te -o /usr/share/selinux/packages/redis-ce.mod 2>/dev/null || true
    semodule_package -m /usr/share/selinux/packages/redis-ce.mod -o /usr/share/selinux/packages/redis-ce.pp -f /usr/share/selinux/packages/redis-ce.fc 2>/dev/null || true
    semodule -i /usr/share/selinux/packages/redis-ce.pp 2>/dev/null || true
fi
if command -v chcon &>/dev/null; then
    chcon -t redis_conf_t /etc/redis/sentinel /etc/redis/sentinel/sentinel.conf 2>/dev/null || true
fi

%files
/usr/bin/redis-server
/usr/bin/redis-cli
/usr/bin/redis-sentinel
/usr/bin/redis-benchmark
/usr/bin/redis-check-aof
/usr/bin/redis-check-rdb
%config(noreplace) /etc/redis/redis.conf
%config(noreplace) /etc/redis/sentinel/sentinel.conf
%attr(750,redis,redis) /var/lib/redis
%attr(750,redis,redis) /var/log/redis
/usr/lib/redis/modules/
/usr/lib/systemd/system/redis.service
/usr/lib/systemd/system/redis-sentinel.service
/usr/share/selinux/packages/redis-ce.te
/usr/share/selinux/packages/redis-ce.fc
SPECEOF

sed -i "s/REPLACE_VERSION/${VERSION}/g" ~/rpmbuild/SPECS/redis.spec
sed -i "s|REPLACE_BUILD_CMD|${BUILD_CMD}|" ~/rpmbuild/SPECS/redis.spec

rpmbuild -bb ~/rpmbuild/SPECS/redis.spec

# --- collect (exclude debuginfo/debugsource) ---------------------------------
find ~/rpmbuild/RPMS -name "*.rpm" ! -name "*debug*" -exec cp {} /workspace/dist/ \;
echo "== built =="
ls -lh /workspace/dist/
