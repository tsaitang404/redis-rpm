#!/bin/bash
# Build one Redis RPM inside a Rocky Linux container.
# Env: REDIS_VERSION (e.g. 8.10.1)
set -ex

VERSION="${REDIS_VERSION:?REDIS_VERSION not set}"
ARCH=$(uname -m)
MAJOR=$(echo "$VERSION" | cut -d. -f1)

# --- dependencies ------------------------------------------------------------
dnf install -y -q gcc gcc-c++ make cmake wget tar gzip rpm-build \
  python3 python3-pip openssl-devel which 2>&1 | tail -1

# --- fetch source ------------------------------------------------------------
cd /tmp
wget -q "https://download.redis.io/releases/redis-${VERSION}.tar.gz"
tar xzf "redis-${VERSION}.tar.gz"
cd "redis-${VERSION}"

mkdir -p /build/dist
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
tar czf ~/rpmbuild/SOURCES/redis-${VERSION}.tar.gz -C /tmp redis-${VERSION}

# --- build command (8.x uses 'make build core', older uses plain make) -------
if [ "$MAJOR" -ge 8 ]; then
  BUILD_CMD='make build core -j$(nproc)'
else
  BUILD_CMD='make -j$(nproc) MALLOC=libc'
fi

cat > ~/rpmbuild/SPECS/redis.spec <<EOF
%define debug_package %{nil}
Name:           redis
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Redis in-memory key-value database (auto build)
License:        RSALv2/SSPLv1/AGPLv3
URL:            https://redis.io
Source0:        redis-${VERSION}.tar.gz
BuildRequires:  gcc, make, cmake, python3

%description
Redis is an in-memory data structure store used as database, cache and message
broker. Auto-built from tsaitang404/redis-rpm pipeline.

%prep
%setup -q

%build
${BUILD_CMD}

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}{/usr/bin,/etc/redis,/var/lib/redis,/var/log/redis,/run/redis,/usr/lib/systemd/system}
install -m 755 src/redis-server     %{buildroot}/usr/bin/
install -m 755 src/redis-cli        %{buildroot}/usr/bin/
install -m 755 src/redis-benchmark  %{buildroot}/usr/bin/
install -m 755 src/redis-check-aof  %{buildroot}/usr/bin/
install -m 755 src/redis-check-rdb  %{buildroot}/usr/bin/
ln -s redis-server %{buildroot}/usr/bin/redis-sentinel
install -m 640 redis.conf    %{buildroot}/etc/redis/redis.conf
install -m 640 sentinel.conf %{buildroot}/etc/redis/sentinel.conf
cat > %{buildroot}/usr/lib/systemd/system/redis.service <<'SVCEOF'
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
Type=notify
User=redis
Group=redis
ExecStart=/usr/bin/redis-server /etc/redis/redis.conf --supervised systemd
ExecStop=/usr/bin/redis-cli shutdown
Restart=always
LimitNOFILE=65535
RuntimeDirectory=redis

[Install]
WantedBy=multi-user.target
SVCEOF

%pre
getent group redis  >/dev/null || groupadd -r redis
getent passwd redis >/dev/null || useradd -r -g redis -d /var/lib/redis -s /sbin/nologin redis

%files
/usr/bin/redis-server
/usr/bin/redis-cli
/usr/bin/redis-sentinel
/usr/bin/redis-benchmark
/usr/bin/redis-check-aof
/usr/bin/redis-check-rdb
%config(noreplace) /etc/redis/redis.conf
%config(noreplace) /etc/redis/sentinel.conf
%attr(750,redis,redis) /var/lib/redis
%attr(750,redis,redis) /var/log/redis
/usr/lib/systemd/system/redis.service
EOF

rpmbuild -bb ~/rpmbuild/SPECS/redis.spec

# --- collect -----------------------------------------------------------------
find ~/rpmbuild/RPMS -name "*.rpm" -exec cp {} /build/dist/ \;
echo "== built =="
ls -lh /build/dist/
