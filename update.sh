#!/bin/sh

cd "$(dirname "$0")"
export IOTSR_DEVICE_ID="$(hostname)"

# Code
git fetch
changed="$(git log --oneline master..origin/master)"
if [ -n "$changed" ]; then
    git pull -X theirs > /dev/null
    docker-compose up -d --build
fi

# Config
url="https://raw.githubusercontent.com/frantp/iot-utils/master/cfg/ln/${IOTSR_DEVICE_ID}.yml"
relink="$(wget -qO- "${url}")"
if [ -n "$relink" ]; then
    urlf="$(dirname "${url}")/${relink}"
    ofile="./etc/sreader.yml"
    wget -qO "${ofile}" "${urlf}"
else
    echo "File not found at '${url}'" &>2
fi
