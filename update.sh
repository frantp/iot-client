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
    mkdir -p \"${LIB_DIR}\" \"${LOG_DIR}\"
    cd "sreader"
    env_changed="$(git log --oneline master..origin/master -- "requirements.txt" 2> /dev/null)"
    cd ".."

    # Configuration
    echo "- Configuring"
    raspi-config nonint do_i2c 0
    raspi-config nonint do_serial 2

    # Dependencies
    echo "- Installing dependencies"
    until [ -n "${installed}" ]; do
        . "/etc/os-release"
        curl -sL https://repos.influxdata.com/influxdb.key | sudo apt-key add - && \
        echo "deb https://repos.influxdata.com/debian ${VERSION_CODENAME} stable" > "/etc/apt/sources.list.d/influxdb.list" && \
        apt-get -qq update && \
        apt-get -qq install curl git jq mosquitto telegraf \
            python3 python3-venv python3-smbus python3-pil libopenjp2-7 && \
        installed=true || true
        if [ -z "${installed}" ]; then
            echo "Retrying installation"
            sleep 1
        fi
    done
    usermod -aG dialout,spi,i2c,gpio telegraf
    systemctl enable mosquitto telegraf > /dev/null

    # Source code
    echo "- Updating source code"
    git reset --hard origin/master > /dev/null
    git submodule update --remote > /dev/null

    if [ -n "${force}" ] || [ -n "${env_changed}" ]; then
        echo "- Installing Python environment"
        python3 -m venv "${LIB_DIR}/env"
        . "${LIB_DIR}/env/bin/activate"
        pip3 install --no-cache-dir -r "sreader/requirements.txt"
        deactivate
    else
        echo "- Python environment up to date"
    fi

    # Environment
    echo "- Setting up environment"
    # - Logrotate
    cp "logrotate.conf" "${LOGROTATE_CFG}"
    # - Exe
    echo "#!/bin/sh
\"${LIB_DIR}/env/bin/python3\" -u \"${SRC_DIR}/sreader/src/run.py\" \"\$@\"" > "${MAIN_EXE}"
    chmod +x "${MAIN_EXE}"
    # - Cron job
    echo "#!/bin/sh
echo \"\$(date -Ins)\" >> \"${UPDATER_LOG}\"
\"${UPDATER_EXE}\" >> \"${UPDATER_LOG}\" 2>&1" > "${CRON_EXE}"
    chmod +x "${CRON_EXE}"
    # - Updater
    cp "${SRC_DIR}/update.sh" "${UPDATER_EXE}"
    chmod +x "${UPDATER_EXE}"
else
    echo "Up to date"
fi

# Config
echo "Updating configuration files"
download_github_file "${cfg_url}/mosquitto.conf" "/etc/mosquitto/conf.d/sreader.conf"
#download_github_file "${cfg_url}/telegraf.conf" "/etc/telegraf/conf.d/sreader.conf"
download_github_file "${cfg_url}/telegraf.conf" "/etc/telegraf/telegraf.conf"
download_github_file "${cfg_url}/sreader.conf" "/etc/sreader.conf"

# Restarting services
echo "Restarting services"
systemctl restart mosquitto telegraf > /dev/null

echo "Finished"
