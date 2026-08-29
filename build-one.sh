#!/bin/bash
set -ex
VERSION="${REDIS_VERSION:?REDIS_VERSION not set}"
# Install rpmbuild if missing
command -v rpmbuild || dnf install -y -q rpm-build 2>&1 | tail -1

MAJOR=$(echo "$VERSION" | cut -d. -f1)

# --- fetch source ---
cd /tmp
if [ "$MAJOR" -ge 8 ]; then
  git clone --depth 1 --branch "$VERSION" https://github.com/redis/redis.git "redis-${VERSION}" 2>&1 | tail -3
  cd "redis-${VERSION}"
  git submodule update --init --recursive 2>&1 | tail -5 || true
else
  wget -q "https://download.redis.io/releases/redis-${VERSION}.tar.gz"
  tar xzf "redis-${VERSION}.tar.gz"
  cd "redis-${VERSION}"
fi

mkdir -p /workspace/dist ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
tar czf ~/rpmbuild/SOURCES/redis-${VERSION}.tar.gz -C /tmp "redis-${VERSION}"

cat > ~/rpmbuild/SPECS/redis.spec <<'SPECEOF'
%define debug_package %{nil}
Name:           redis
Version:        REPLACE_VERSION
Release:        1%{?dist}
Summary:        Redis in-memory key-value database
License:        BSD-3-Clause
URL:            https://redis.io
Source0:        redis-REPLACE_VERSION.tar.gz
BuildRequires:  gcc, make

%description
Redis core + available bundled modules.

%prep
%setup -q

%build
MAJOR=$(echo "REPLACE_VERSION" | cut -d. -f1)
# Build core first (always succeeds)
make -C src all -j$(nproc)
# Build modules for 8.x (continue on failure)
if [ "$MAJOR" -ge 8 ]; then
  make bootstrap 2>&1 | tail -5 || true
  for mod in redisbloom redistimeseries redisearch redisjson; do
    [ -d "modules/$mod" ] && make -C modules/$mod -j$(nproc) 2>&1 | tail -3 || echo "==> $mod: FAILED"
  done
fi

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}{/usr/bin,/etc/redis/sentinel,/var/lib/redis,/var/log/redis,/run/redis,/run/sentinel,/usr/lib/redis/modules,/usr/lib/systemd/system,/usr/share/selinux/packages}
install -m 755 src/redis-server %{buildroot}/usr/bin/
install -m 755 src/redis-cli %{buildroot}/usr/bin/
install -m 755 src/redis-benchmark %{buildroot}/usr/bin/
install -m 755 src/redis-check-aof %{buildroot}/usr/bin/
install -m 755 src/redis-check-rdb %{buildroot}/usr/bin/
ln -s redis-server %{buildroot}/usr/bin/redis-sentinel
# Install available module .so files
for so in bin/linux-*-release/*.so bin/linux-*-release/search-community/*.so; do
  [ -f "$so" ] && install -m 755 "$so" %{buildroot}/usr/lib/redis/modules/
done
install -m 640 redis.conf %{buildroot}/etc/redis/redis.conf
install -m 640 sentinel.conf %{buildroot}/etc/redis/sentinel/sentinel.conf
cat > %{buildroot}/usr/lib/systemd/system/redis.service <<'SVC'
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
SVC
cat > %{buildroot}/usr/lib/systemd/system/redis-sentinel.service <<'SVC'
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
SVC
cat > %{buildroot}/usr/share/selinux/packages/redis-ce.te <<'SE'
module redis-ce 1.0;
require { type redis_t; type redis_conf_t; class file { read write open }; }
allow redis_t redis_conf_t:file { read write open };
SE
cat > %{buildroot}/usr/share/selinux/packages/redis-ce.fc <<'SE'
/etc/redis(/.*)?    gen_context(system_u:object_r:redis_conf_t,s0)
/run/redis(/.*)?    gen_context(system_u:object_r:redis_var_run_t,s0)
SE

%pre
getent group redis >/dev/null || groupadd -r redis
getent passwd redis >/dev/null || useradd -r -g redis -d /var/lib/redis -s /sbin/nologin redis

%post
command -v checkmodule &>/dev/null && {
  checkmodule -M -m /usr/share/selinux/packages/redis-ce.te -o /usr/share/selinux/packages/redis-ce.mod 2>/dev/null || true
  semodule_package -m /usr/share/selinux/packages/redis-ce.mod -o /usr/share/selinux/packages/redis-ce.pp -f /usr/share/selinux/packages/redis-ce.fc 2>/dev/null || true
  semodule -i /usr/share/selinux/packages/redis-ce.pp 2>/dev/null || true
}
command -v chcon &>/dev/null && chcon -t redis_conf_t /etc/redis/sentinel /etc/redis/sentinel/sentinel.conf 2>/dev/null || true

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

rpmbuild -bb ~/rpmbuild/SPECS/redis.spec --define '__os_install_post %{nil}'
find ~/rpmbuild/RPMS -name "*.rpm" ! -name "*debug*" -exec cp {} /workspace/dist/ \;
echo "== built =="
ls -lh /workspace/dist/
