#!/bin/sh

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
	cat <<- EOM
		Usage: $0 [options] [cfg_url]

		Arguments:
		  cfg_url  URL to search for configuration files (defaults to PIOT_CFG_URL)

		Options:
		  -h  Show this help message
	EOM
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
while getopts "h" arg; do
	case "${arg}" in
		h) usage; exit 0 ;;
	esac
done
shift $(( OPTIND - 1 ))

SRC_DIR="$(dirname "$(realpath "$0")")"

CFG_URL="${1:-${PIOT_CONFIG_URL}}"
CFG_URL="${CFG_URL?"Configuration URL not provided"}"

cd "${SRC_DIR}"

# Installation

echo "[$(date -Ins)] Checking source code updates"
git fetch > /dev/null
code_changed="$(git log --oneline master..origin/master 2> /dev/null)"
status=0
if [ -z "${code_changed}" ]; then
	echo "Source code up to date"
else
	args=""

	deps_changed="$(git diff origin/master -- "dependencies.txt" 2> /dev/null)"
	if [ -z "${deps_changed}" ]; then
		echo "System dependencies up to date"
		args="${args} -s"
	fi

	cd "piot"
	reqs_changed="$(git diff origin/master -- "requirements.txt" 2> /dev/null)"
	if [ -z "${reqs_changed}" ]; then
		echo "Python requirements up to date"
		args="${args} -p"
	fi
	cd ".."

	echo "Updating source code"
	git reset --hard origin/master > /dev/null
	git submodule update --remote > /dev/null

	echo "Reinstalling"
	"./install.sh" ${args} "${CFG_URL}" && status=0 || status=1
fi
host="$(hostname)"
HOME="/root" mosquitto_pub -q 2 -i "piot-update" -t "meta/${host}/update" \
	-m "update,host=${host} status=${status} $(date +%s%N)" 2> /dev/null

# Configuration files

echo "Updating configuration files"
download_github_file "${CFG_URL}/mosquitto.conf" "${TMP_DIR}/mosquitto.conf"
file="/etc/mosquitto/conf.d/piot.conf"
if [ ! -e "${file}" ] || ! diff -q "${TMP_DIR}/mosquitto.conf" "${file}" > /dev/null; then
	mv "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/piot.conf"
	restart_mosquitto=true
fi
download_github_file "${CFG_URL}/telegraf.conf" "${TMP_DIR}/telegraf.conf"
file="/etc/telegraf/telegraf.conf"
if [ ! -e "${file}" ] || ! diff -q "${TMP_DIR}/telegraf.conf" "${file}" > /dev/null; then
	mv "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf"
	restart_telegraf=true
fi
download_github_file "${CFG_URL}/piot.conf" "${TMP_DIR}/piot.conf"
file="/etc/piot.conf"
if [ ! -e "${file}" ] || ! diff -q "${TMP_DIR}/piot.conf" "${file}" > /dev/null; then
	mv "${TMP_DIR}/piot.conf" "/etc/piot.conf"
	restart_piot=true
fi

# Services

echo "Setting up services"
if [ -n "${restart_mosquitto}" ]; then
	echo "- Restarting mosquitto"
	pidof systemd && systemctl -q restart mosquitto
fi
if [ -n "${restart_telegraf}" ]; then
	echo "- Restarting telegraf"
	pidof systemd && systemctl -q restart telegraf
fi
if [ -n "${restart_piot}" ]; then
	echo "- Restarting piot and piot-update.timer"
	pidof systemd && systemctl -q restart piot piot-update.timer
fi
for unit in mosquitto telegraf piot piot-update.timer; do
	if systemctl -q is-enabled "${unit}"; then
		echo "- Enabling ${unit}"
		systemctl -q enable  "${unit}"
	fi
	if pidof systemd && systemctl -q is-active  "${unit}"; then
		echo "- Starting ${unit}"
		systemctl -q restart "${unit}"
	fi
done
systemctl daemon-reload 2> /dev/null
