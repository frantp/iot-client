#!/bin/sh

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

download_github_file() {
    url="$1"
    filename="$(basename "${url}")"
    res="$(wget "${url}" -qO-)" || \
        die "Configuration file not found at '${url}'"
    rt="$(echo "${res}" | tr -d '\r\n')" && \
    echo "${rt}" | jq -r '.content' | base64 -d > "${filename}"
}

download_github_dir() {
    url="$1"
    res="$(wget "${url}" -qO-)" || \
        die "Configuration directory not found at '${url}'"
    rt="$(echo "${res}" | tr -d '\r\n')" && \
    rfiles="$(echo "${rt}" | jq -r '.[] | select(.type == "file").url')" && \
    rdirs="$(echo "${rt}" | jq -r '.[] | select(.type == "dir").url')" ||
        die "Error processing response"
    while read -r url; do
        download_github_file "${url}"
    done <<< "${rfiles}"
    while read -r url; do
        dirname="$(basename "${url}")"
        pushd "${dirname}"
        download_github_dir "${url}"
        popd
    done <<< "${rdirs}"
}

cfg_url_prefix="${1?"$(usage)"}"

cd "$(dirname "$0")"

# Code
git fetch
changed="$(git log --oneline master..origin/master)"
if [ -n "$changed" ]; then
    git pull -X theirs > /dev/null
    docker-compose up -d --build
fi

# Config
url="${cfg_url_prefix}/${IOTSR_DEVICE_ID}"
res="$(wget "${url}" -qO-)" || \
    die "Configuration directory not found at '${url}'"
pushd "etc"
download_github_dir "${url}"
popd
