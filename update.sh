#!/bin/sh -e

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
    echo ""
    echo "Usage: $0 [options] [cfg_url]"
    echo ""
    echo "Arguments:"
    echo "  cfg_url  URL to search for configuration files (defaults to SREADER_CFG_URL)"
    echo ""
    echo "Options:"
    echo "  -h  Show this help message"
    echo "  -f  Force update"
}

download_github_file() {
    url="${1?"URL not provided"}"
    path="${2?"Path not provided"}"
    res="$(wget "${url}" -qO-)" || \
        die "Configuration file not found at '${url}'"
    echo "${res}" | tr -d '\r\n' | jq -r '.content' | base64 -d > "${path}"
    echo "- Downloaded '${url}' to '${path}'"
}

# Parse arguments
while getopts "hf" arg; do
    case "${arg}" in
        h) usage; exit 0 ;;
        f) force=true ;;
    esac
done
shift $(( OPTIND - 1 ))

SRC_DIR="/opt/iot-client"
MAIN_EXE="/usr/local/bin/sreader"
LIB_DIR="/var/lib/sreader"
LOG_DIR="/var/log/sreader"
SERVICES_DIR="/etc/systemd/system"
CRON_EXE="/etc/cron.hourly/sreader-update"
UPDATER_EXE="/usr/local/bin/sreader-update"
UPDATER_LOG="${LOG_DIR}/updater.log"
LOGROTATE_CFG="/etc/logrotate.d/sreader"

cfg_url="${1:-${SREADER_CFG_URL}}"

cd "${SRC_DIR}"

# Source
echo "Checking source code updates"
git fetch > /dev/null
changed="$(git log --oneline master..origin/master 2> /dev/null)"
if [ -n "${force}" ] || [ -n "${changed}" ]; then
    env_changed="$(git log --oneline master..origin/master sreader/requirements.txt 2> /dev/null)"

    # Configuration
    echo "- Configuring"
    raspi-config nonint do_i2c 0
    raspi-config nonint do_serial 0

    # Dependencies
    echo "- Installing dependencies"
    until [ -n "${installed}" ]; do
        apt-get -qq update && \
        apt-get -qq install curl git jq mosquitto python3 python3-venv python3-smbus python3-pil && \
        installed=true || true
        if [ -z "${installed}" ]; then
            echo "Retrying installation"
            sleep 1
        fi
    done
    systemctl enable mosquitto

    # Source code
    echo "- Updating source code"
    git reset --hard origin/master > /dev/null
    git submodule update --remote > /dev/null

    mkdir -p \"${LIB_DIR}\" \"${LOG_DIR}\"

    if [ -n "${force}" ] || [ -n "${env_changed}" ]; then
        echo "- Installing Python environment"

        python3 -m venv "${LIB_DIR}/env"
        . "${LIB_DIR}/env/bin/activate"
        pip3 install --no-cache-dir -r "sreader/requirements.txt"
        deactivate
    fi

    # Environment
    echo "- Setting up environment"
    # - Logrotate
    cp "logrotate.conf" "${LOGROTATE_CFG}"
    # - Exe
    echo "#/bin/sh
\"${LIB_DIR}/env/bin/python3\" \"${SRC_DIR}/sreader/src/loop.py\" \"\$@\"" > "${MAIN_EXE}"
    chmod +x "${MAIN_EXE}"
    # - Service
    cp "sreader.service" "${SERVICES_DIR}"
    systemctl daemon-reload
    systemctl enable sreader
    # - Cron job
    echo "#/bin/sh
\"${UPDATER_EXE}\" \"\${SREADER_CFG_URL}\" >> \"${UPDATER_LOG}\" 2>&1" > "${CRON_EXE}"
    chmod +x "${CRON_EXE}"
    # - Updater
    cp "${SRC_DIR}/update.sh" "${UPDATER_EXE}"
    chmod +x "${UPDATER_EXE}"
else
    echo "No updates"
fi

# Config
echo "Updating configuration files"
download_github_file "${cfg_url}/mosquitto.conf" "/etc/mosquitto/mosquitto.conf"
download_github_file "${cfg_url}/sreader.conf" "/etc/sreader.conf"

# Restarting services
echo "Restarting services"
systemctl restart mosquitto sreader

echo "Finished"
