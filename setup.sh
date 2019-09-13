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
    echo "  -s  Omit installation of system requirements"
    echo "  -p  Omit installation of Python requirements"
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
while getopts "hsp" arg; do
    case "${arg}" in
        h) usage; exit 0 ;;
        s) omit_system_reqs=true ;;
        p) omit_python_reqs=true ;;
    esac
done
shift $(( OPTIND - 1 ))

SRC_DIR="$(realpath "$(dirname "$0")")"
MAIN_EXE="/usr/local/bin/sreader"
LIB_DIR="/var/lib/sreader"
LOG_DIR="/var/log/sreader"
SERVICES_DIR="/etc/systemd/system"
TMP_DIR="/run/sreader"
CRON_EXE="/etc/cron.hourly/sreader-update"
UPDATER_EXE="/usr/local/bin/sreader-update"
UPDATER_LOG="${LOG_DIR}/updater.log"
LOGROTATE_CFG="/etc/logrotate.d/sreader"

cfg_url="${1:-${SREADER_CFG_URL}}"

cd "${SRC_DIR}" %%%%%%%

mkdir -p "${LIB_DIR}" "${LOG_DIR}" "${TMP_DIR}"

# System requirements
if [ -z "${omit_system_reqs}" ]; then
    echo "Installing system requirements"
    until [ -n "${installed}" ]; do
        . "/etc/os-release"
        curl -sL "https://repos.influxdata.com/influxdb.key" | sudo apt-key add - && \
        echo "deb https://repos.influxdata.com/debian ${VERSION_CODENAME} stable" > "/etc/apt/sources.list.d/influxdb.list" && \
        apt-get -qq update && \
        apt-get -qq install $(cat requirements.list | tr '\n' ' ') && \
        installed=true || true
        if [ -z "${installed}" ]; then
            echo "Retrying installation"
            sleep 1
        fi
    done
fi

# Configuration
echo "Configuring"
raspi-config nonint do_i2c 0
raspi-config nonint do_serial 2

# Python requirements
if [ -z "${omit_python_reqs}" ]; then
    echo "- Installing Python requirements"
    python3 -m venv "${LIB_DIR}/env"
    . "${LIB_DIR}/env/bin/activate"
    pip3 install --no-cache-dir -r "sreader/requirements.txt"
    deactivate
fi

# Files
echo "Installing files"
# - Logrotate
cp "logrotate.conf" "${LOGROTATE_CFG}"
# - Exe
echo "#!/bin/sh
\"${LIB_DIR}/env/bin/python3\" -u \"${SRC_DIR}/sreader/src/run.py\" \"\$@\"" > "${MAIN_EXE}"
chmod +x "${MAIN_EXE}"
# - Services
cp "${SRC_DIR}/sreader.service" "${SERVICES_DIR}"
# - Cron job
echo "#!/bin/sh
\"${UPDATER_EXE}\" >> \"${UPDATER_LOG}\" 2>&1" > "${CRON_EXE}"
chmod +x "${CRON_EXE}"
# - Updater
cp "${SRC_DIR}/update.sh" "${UPDATER_EXE}"
chmod +x "${UPDATER_EXE}"

# Configuration files
echo "Updating configuration files"
download_github_file "${cfg_url}/mosquitto.conf" "${TMP_DIR}/mosquitto.conf"
if ! diff -q "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/sreader.conf" > /dev/null; then
    echo "Restarting mosquitto"
    mv "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/sreader.conf"
    systemctl restart mosquitto
fi
download_github_file "${cfg_url}/telegraf.conf" "${TMP_DIR}/telegraf.conf"
if ! diff -q "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf" > /dev/null; then
    echo "Restarting telegraf"
    mv "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf"
    systemctl restart telegraf
fi
download_github_file "${cfg_url}/sreader.conf" "/etc/sreader.conf"

# Services
echo "Setting up services"
systemctl daemon-reload
systemctl is-enabled mosquitto > /dev/null || systemctl enable mosquitto
systemctl is-enabled telegraf  > /dev/null || systemctl enable telegraf
systemctl is-enabled sreader   > /dev/null || systemctl enable sreader
systemctl is-active  mosquitto > /dev/null || systemctl restart mosquitto
systemctl is-active  telegraf  > /dev/null || systemctl restart telegraf
systemctl restart sreader

echo "Finished"
