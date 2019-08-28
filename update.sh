#!/bin/sh -e

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <cfg_url>"
}

download_github_file() {
    url="${1?"URL not provided"}"
    filename="$(basename "${url}")"
    res="$(wget "${url}" -qO-)" || \
        die "Configuration file not found at '${url}'"
    rt="$(echo "${res}" | tr -d '\r\n')" && \
    echo "${rt}" | jq -r '.content' | base64 -d > "${filename}"
    echo "- Downloaded '${url}' to '$(realpath "${filename}")'"
}

download_github_dir() {
    url="${1?"URL not provided"}"
    res="$(wget "${url}" -qO-)" || \
        die "Configuration directory not found at '${url}'"
    rt="$(echo "${res}" | tr -d '\r\n')" && \
    rfiles="$(echo "${rt}" | jq -r '.[] | select(.type == "file").url')" && \
    rdirs="$(echo "${rt}" | jq -r '.[] | select(.type == "dir").url')" ||
        die "Error processing response"
    if [ -n "${rfiles}" ]; then
        echo "${rfiles}" | while read -r url; do
            url="${url%%\?*}"
            download_github_file "${url}"
        done
    fi
    if [ -n "${rdirs}" ]; then
        echo "${rdirs}" | while read -r url; do
            url="${url%%\?*}"
            dirname="$(basename "${url}")"
            cd "${dirname}"
            download_github_dir "${url}"
            cd ..
        done
    fi
}

cfg_url="${1?"$(usage)"}"

cd "$(dirname "$0")"

# Code
echo "Checking source code updates"
git fetch > /dev/null
changed="$(git log --oneline master..origin/master)"
if [ -n "$changed" ]; then
    echo "Updating source code"
    git reset --hard origin/master > /dev/null
    git submodule update --remote > /dev/null
    echo "Rebuilding containers"
    docker-compose up -d --build
else
    echo "No updates"
fi

# Config
echo "Updating configuration files"
cd "etc"
download_github_dir "${cfg_url}"
cd ..

echo "Finished"
