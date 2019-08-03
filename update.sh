#!/bin/bash
cd "$(dirname "$0")"
git pull -X theirs > /dev/null
readonly url="https://raw.githubusercontent.com/frantp/iot-config/master/links/$(hostname).yml"
readonly relink="$(wget -qO - "${url}")"
if [ -n "$relink" ]; then
    readonly urlf="$(dirname "${url}")/${relink}"
    readonly ofile="./etc/sreader.yml"
    wget -qO "${ofile}_" "${urlf}"
else
    echo "File not found at '${url}'"
fi