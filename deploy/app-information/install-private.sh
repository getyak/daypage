#!/bin/bash
# Reviewed private preparation only: does not open a public port or change DNS.
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "$(id -u)" = 0
source_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
payload=${1:?usage: install-private.sh path-to-reviewed-app-info.json}
test -f "$payload" && test ! -L "$payload"
test ! -e /etc/daypage-app-information
test ! -e /usr/share/daypage-app-information
test ! -e /etc/systemd/system/daypage-app-information.service
if ss -H -ltn | awk '{print $4}' | /bin/grep -Eq '(^|:)18080$'; then
    echo 'Port 18080 is already owned; refusing to replace a listener.' >&2
    exit 1
fi
python3 - "$payload" <<'PY'
import json,sys
data=open(sys.argv[1],'rb').read()
assert 0 < len(data) <= 128*1024
document=json.loads(data.decode('utf-8'))
assert document['schemaVersion']==1 and document['appID']=='com.daypage.app'
assert set(document['languages'])=={'en','zh-Hans'}
print('public_payload_preflight=ok')
PY
if ! command -v nginx >/dev/null 2>&1; then
    dnf install -y nginx
fi
test -x /usr/sbin/nginx
id nginx >/dev/null
install -d -m0755 /etc/daypage-app-information /usr/share/daypage-app-information
install -m0644 "$source_dir/nginx-private.conf" /etc/daypage-app-information/nginx.conf
install -m0644 "$payload" /usr/share/daypage-app-information/app-info.json
install -m0644 "$source_dir/daypage-app-information.service" /etc/systemd/system/daypage-app-information.service
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/daypage-app-information.service
systemctl enable --now daypage-app-information.service
test "$(systemctl show -p ActiveState --value daypage-app-information.service)" = active
printf 'private_service_started=true public_exposure=false\n'
sha256sum /usr/share/daypage-app-information/app-info.json
