#!/bin/bash
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "$(id -u)" = 0
expected_hash=${1:?usage: verify-private.sh reviewed-payload-sha256}
[[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]]
test "$(systemctl show -p ActiveState --value daypage-app-information.service)" = active
work=$(mktemp -d /run/daypage-information-check.XXXXXX)
trap 'rm -f -- "$work/body" "$work/headers"; rmdir -- "$work"' EXIT
origin=http://127.0.0.1:18080
path=/daypage/v1/app-info.json
status=$(curl --noproxy '*' --connect-timeout 1 --max-time 4 -sS -D "$work/headers" -o "$work/body" -w '%{http_code}' -H 'Host: daypage-api.cubxxw.com' "$origin$path")
test "$status" = 200
printf '%s %s\n' "$expected_hash" "$work/body" | sha256sum -c -
tr -d '\015' < "$work/headers" | /bin/grep -Eiq '^Content-Type: application/json$'
tr -d '\015' < "$work/headers" | /bin/grep -Eiq '^Cache-Control: no-store$'
for request in 'POST /daypage/v1/app-info.json 405' 'GET / 404' 'GET /other 404'; do
    read -r method route expected <<< "$request"
    actual=$(curl --noproxy '*' --connect-timeout 1 --max-time 4 -sS -o /dev/null -w '%{http_code}' -X "$method" -H 'Host: daypage-api.cubxxw.com' "$origin$route")
    test "$actual" = "$expected"
    printf 'method=%s path=%s status=%s\n' "$method" "$route" "$actual"
done
test "$(curl --noproxy '*' --max-time 4 -sS -o /dev/null -w '%{http_code}' "$origin$path")" = 404
# The configured listener must remain loopback-only while filing is pending.
test "$(ss -H -ltn | awk '$4 ~ /:18080$/ {print $4}')" = 127.0.0.1:18080
cmp -s /etc/daypage-app-information/nginx.conf "$(dirname -- "$0")/nginx-private.conf"
printf 'private_http_contract=passed public_dns_tls_filing_and_app_release=pending\n'
