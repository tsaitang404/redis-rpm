#!/bin/bash
# Build one Redis RPM inside a Rocky Linux container.
# Env: REDIS_VERSION (e.g. 8.10.1), optional REDIS_SOURCE_URL
set -ex

VERSION="${REDIS_VERSION:?REDIS_VERSION not set}"
ARCH=$(uname -m)
BUILDER=/tmp/redis-rpm-builder

dnf install -y -q gcc make rpm-build wget tar gzip jemalloc-devel || \
dnf install -y -q gcc make rpm-build wget tar gzip

# --- fetch source ------------------------------------------------------------
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS} "$BUILDER/dist"
cd /tmp
if [ -n "$REDIS_SOURCE_URL" ]; then
  wget -q "$REDIS_SOURCE_URL" -O "redis-${VERSION}.tar.gz"
else
  wget -q "https://download.redis.io/releases/redis-${VERSION}.tar.gz"
fi
cp "redis-${VERSION}.tar.gz" ~/rpmbuild/SOURCES/

# Extract once to grab configs from the redis-rpm repo (if mounted) or defaults
tar xzf "redis-${VERSION}.tar.gz"

# Use repo configs when available (repo is mounted at /workspace)
if [ -d /workspace/configs ]; then
  cp /workspace/configs/redis.conf        redis.conf
  cp /workspace/configs/sentinel.conf     sentinel.conf
  SVC_SRC=/workspace/configs/redis.service
else
  SVC_SRC=""
fi

MAJOR=$(echo "$VERSION" | cut -d. -f1)

# --- spec --------------------------------------------------------------------
cat > ~/rpmbuild/SPECS/redis.spec <<EOF
Name:           redis
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Redis in-memory key-value database (auto build)
License:        BSD-3-Clause
URL:            https://redis.io
Source0:        redis-${VERSION}.tar.gz
BuildRequires:  gcc, make

%description
Redis is an in-memory data structure store used as database, cache and message
broker. Auto-built from redis/redis-rpm pipeline.

%prep
%setup -q

%build
make -j\$(nproc) MALLOC=libc

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
mkdir -p /workspace/dist
find ~/rpmbuild/RPMS -name "*.rpm" -exec cp {} /workspace/dist/ \;
echo "== built =="
ls -lh /workspace/dist/
