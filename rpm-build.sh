#!/bin/bash
set -ex
VERSION="${REDIS_VERSION:?}"
DISTTAG="${DISTTAG:-el9}"
# Fresh copy of staging (rpmbuild wipes buildroot)
rm -rf /tmp/staging-copy && cp -a /tmp/staging /tmp/staging-copy
mkdir -p /tmp/rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
cat > /tmp/rpmbuild/redis.spec << EOF
%define _topdir /tmp/rpmbuild
Name: redis
Version: ${VERSION}
Release: 1.${DISTTAG}
Summary: Redis with bundled modules
License: SSPLv1
BuildArch: x86_64
%define debug_package %{nil}
%define _build_id_links none
%description
Redis with bundled modules
%install
cp -a /tmp/staging-copy/* %{buildroot}/
%files
%dir /etc/redis
%config(noreplace) /etc/redis/redis.conf
%config(noreplace) /etc/redis/sentinel
/usr/bin/redis-server
/usr/bin/redis-cli
/usr/bin/redis-benchmark
/usr/bin/redis-check-rdb
/usr/bin/redis-check-aof
/usr/bin/redis-sentinel
/usr/lib/redis/modules
/usr/lib/systemd/system/redis.service
/usr/lib/systemd/system/redis-sentinel.service
%dir /var/lib/redis
%dir /var/log/redis
%dir /run/redis
%dir /run/sentinel
/usr/share/selinux/packages
EOF
rpmbuild -bb --noclean --buildroot /tmp/rpmbuild/BUILDROOT/redis /tmp/rpmbuild/redis.spec
cp /tmp/rpmbuild/RPMS/x86_64/*.rpm /workspace/dist/
