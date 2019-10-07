#!/bin/sh -e

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
    echo ""
    echo "Usage: $0 [options] [cfg_url]"
    echo ""
    echo "Arguments:"
    echo "  cfg_url  URL to search for configuration files (defaults to PIOT_CFG_URL)"
    echo ""
    echo "Options:"
    echo "  -h  Show this help message"
}

# Parse arguments
while getopts "h" arg; do
    case "${arg}" in
        h) usage; exit 0 ;;
    esac
done
shift $(( OPTIND - 1 ))

SRC_DIR="/opt/piot-client"

cfg_url="${1:-${PIOT_CFG_URL}}"

cd "${SRC_DIR}"

# Source
echo "[$(date -Ins)] Checking source code updates"
git fetch > /dev/null
scode_changed="$(git log --oneline master..origin/master 2> /dev/null)"
if [ -n "${scode_changed}" ]; then
    sreqs_changed="$(git diff origin/master -- "requirements.list" 2> /dev/null)"
    cd "piot"
    preqs_changed="$(git diff origin/master -- "requirements.txt" 2> /dev/null)"
    cd ".."

    echo "Updating source code"
    git reset --hard origin/master > /dev/null
    git submodule update --remote > /dev/null
fi

# Config
args=""
if [ -z "${scode_changed}" ]; then
    echo "Source code up to date"
    args="${args} -o"
fi
if [ -z "${sreqs_changed}" ]; then
    echo "System requirements up to date"
    args="${args} -s"
fi
if [ -z "${preqs_changed}" ]; then
    echo "Python requirements up to date"
    args="${args} -p"
fi

"./install.sh" ${args} "${cfg_url}" && status=0 || status=1

host="$(hostname)"
HOME="/root" mosquitto_pub -q 2 -i "piot-update" -t "state/${host}/update" \
    -m "update,host=${host} status=${status} $(date +%s%N)"
