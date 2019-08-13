#!/bin/sh

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

cd "$(dirname "$0")"

# Code
git fetch
changed="$(git log --oneline master..origin/master)"
if [ -n "$changed" ]; then
    git pull -X theirs > /dev/null
    docker-compose up -d --build
fi

# Config
url="https://api.github.com/repos/frantp/iot-utils/contents/cfg/id/${IOTSR_DEVICE_ID}.conf"
res="$(wget "${url}" -qO-)" || \
    die "Configuration file not found at '${url}'"
echo "${res}" | tr -d '\r\n' | jq -r .content | base64 -d > "./etc/sreader.conf"
