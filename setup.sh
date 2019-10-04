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
    echo "  -o  Omit installation of sreader"
    echo "  -p  Omit installation of Python requirements"
    echo "  -s  Omit installation of system requirements"
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
while getopts "hosp" arg; do
    case "${arg}" in
        h) usage; exit 0 ;;
        o) omit_installation=true ;;
        s) omit_system_reqs=true ;;
        p) omit_python_reqs=true ;;
    esac
done
shift $(( OPTIND - 1 ))

SRC_DIR="/opt/iot-client"
LIB_DIR="/var/lib/sreader"
LOG_DIR="/var/log/sreader"
SERVICES_DIR="/etc/systemd/system"
TMP_DIR="/run/sreader"
MAIN_EXE="/usr/local/bin/sreader"
UPDATER_EXE="/usr/local/bin/sreader-update"
LOGROTATE_CFG="/etc/logrotate.d/sreader"

cfg_url="${1:-${SREADER_CFG_URL}}"

cd "${SRC_DIR}"

if [ -z "${omit_installation}" ]; then
    mkdir -p "${LIB_DIR}" "${LOG_DIR}" "${TMP_DIR}"

    # System requirements
    if [ -z "${omit_system_reqs}" ]; then
        echo "Installing system requirements"
        until [ -n "${installed}" ]; do
            . "/etc/os-release"
            curl -sL "https://repos.influxdata.com/influxdb.key" | sudo apt-key add - > /dev/null && \
            echo "deb https://repos.influxdata.com/debian ${VERSION_CODENAME} stable" > "/etc/apt/sources.list.d/influxdb.list" && \
            apt-get -qq update && \
            DEBIAN_FRONTEND=noninteractive \
            apt-get -qq install $(cat requirements.list | tr '\n' ' ') && \
            installed=true || true
            if [ -z "${installed}" ]; then
                echo "Retrying installation"
                sleep 1
            fi
        done
    fi

    # Python requirements
    if [ -z "${omit_python_reqs}" ]; then
        echo "- Installing Python requirements"
        python3 -m venv "${LIB_DIR}/env"
        . "${LIB_DIR}/env/bin/activate"
        pip3 install --no-cache-dir -r "sreader/requirements.txt"
        deactivate
    fi

    # Configuration
    echo "Configuring"
    raspi-config nonint do_i2c 0
    raspi-config nonint do_serial 2

    # Sreader
    echo "Installing sreader"
    chmod +x "${SRC_DIR}/sreader.sh" "${SRC_DIR}/update.sh" "${SRC_DIR}/setup.sh" "${SRC_DIR}/install.sh"
    ln -sf "${SRC_DIR}/sreader.sh" "${MAIN_EXE}"  # Main exe
    for unit in "sreader.service" "sreader-update.service" "sreader-update.timer"; do
        ln -sf "${SRC_DIR}/systemd/${unit}" "${SERVICES_DIR}/${unit}"  # Services
    done
    systemctl daemon-reload
    ln -sf "logrotate.conf" "${LOGROTATE_CFG}"  # Logrotate
    ln -sf "${SRC_DIR}/update.sh" "${UPDATER_EXE}"  # Updater

    restart_sreader=true
fi

# Configuration files
echo "Updating configuration files"
download_github_file "${cfg_url}/mosquitto.conf" "${TMP_DIR}/mosquitto.conf"
if ! diff -q "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/sreader.conf" > /dev/null; then
    mv "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/sreader.conf"
    restart_mosquitto=true
fi
download_github_file "${cfg_url}/telegraf.conf" "${TMP_DIR}/telegraf.conf"
if ! diff -q "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf" > /dev/null; then
    mv "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf"
    restart_telegraf=true
fi
download_github_file "${cfg_url}/sreader.conf" "${TMP_DIR}/sreader.conf"
if ! diff -q "${TMP_DIR}/sreader.conf" "/etc/sreader.conf" > /dev/null; then
    mv "${TMP_DIR}/sreader.conf" "/etc/sreader.conf"
    restart_sreader=true
fi

# Services
echo "Setting up services"
if [ -n "${restart_mosquitto}" ]; then
    echo "- Restarting mosquitto"
    systemctl restart mosquitto
fi
if [ -n "${restart_telegraf}" ]; then
    echo "- Restarting telegraf"
    systemctl restart telegraf
fi
if [ -n "${restart_sreader}" ]; then
    echo "- Restarting sreader and sreader-update.timer"
    systemctl restart sreader
    systemctl restart sreader-update.timer
fi
for unit in "mosquitto" "telegraf" "sreader" "sreader-update.timer"; do
    systemctl is-enabled "${unit}" > /dev/null || { echo "- Enabling ${unit}" && systemctl enable "${unit}"; }
    systemctl is-active  "${unit}" > /dev/null || { echo "- Starting ${unit}" && systemctl restart "${unit}"; }
done

echo "Finished"
