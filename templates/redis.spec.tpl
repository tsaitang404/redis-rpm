Name:             redis
Version:          REPLACE_VERSION
Release:          1
Summary:          Redis (persistent key-value database with modules)
License:          SSPLv1 and RSALv2 and BSD
URL:              https://redis.io
Requires(pre):    shadow-utils
Requires(post):   systemd
Requires(preun):  systemd
Requires(postun): systemd
BuildRequires:    systemd
%define debug_package %{nil}
%global _enable_debug_package 0
%global __os_install_post %{nil}
%description
Redis REPLACE_VERSION with bundled modules.
%install
# Files already staged in buildroot
%files
/usr/bin/
/usr/lib/redis/modules/
/usr/lib/systemd/system/
%config(noreplace) /etc/redis/
/var/
/run/
/usr/share/selinux/
%pre
getent group redis &>/dev/null || groupadd -r redis
getent passwd redis &>/dev/null || useradd -r -g redis -d /var/lib/redis -s /sbin/nologin redis
%post
systemctl daemon-reload
%preun
if [ $1 -eq 0 ]; then
  systemctl stop redis.service redis-sentinel.service 2>/dev/null || true
  systemctl disable redis.service redis-sentinel.service 2>/dev/null || true
fi
%postun
if [ $1 -ge 1 ]; then
  systemctl try-restart redis.service redis-sentinel.service 2>/dev/null || true
fi
