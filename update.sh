#!/bin/sh

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
	cat <<- EOM
		Usage: $0 [options] [cfg_dir]

		Arguments:
		  cfg_url  Directory to search for configuration files
		           (defaults to ../piot-config)

		Options:
		  -h       Show this help message
	EOM
}

# Parse arguments
while getopts "h" arg; do
	case "${arg}" in
		h) usage; exit 0 ;;
	esac
done
shift $(( OPTIND - 1 ))

SRC_DIR="$(dirname "$(realpath "$0")")"
CFG_DIR="${1:-"$(dirname "${SRC_DIR}")/piot-config"}"

# Installation

echo "[$(date -Ins)] Checking source code updates"
cd "${SRC_DIR}"
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
	"./install.sh" ${args} && status=0 || status=1
	restart_piot=true
fi

# Configuration


echo "[$(date -Ins)] Checking configuration updates"
cd "${CFG_DIR}"
git fetch > /dev/null
git reset --hard origin/master > /dev/null
# TODO: Make this automatic through configuration file inside repo
#       ifile:ofile:services...
ifile="$(hostname)/advanced.config"
ofile="/etc/rabbitmq/advanced.config"
if [ ! -e "${ofile}" ] || ! diff -q "${ifile}" "${ofile}" > /dev/null; then
	cp "${ifile}" "${ofile}"
	restart_rabbitmq=true
fi
ifile="$(hostname)/telegraf.conf"
ofile="/etc/telegraf/telegraf.conf"
if [ ! -e "${ofile}" ] || ! diff -q "${ifile}" "${ofile}" > /dev/null; then
	cp "${ifile}" "${ofile}"
	restart_telegraf=true
fi
ifile="$(hostname)/piot.conf"
ofile="/etc/piot.conf"
if [ ! -e "${ofile}" ] || ! diff -q "${ifile}" "${ofile}" > /dev/null; then
	cp "${ifile}" "${ofile}"
	restart_piot=true
fi

# Services

echo "[$(date -Ins)] Setting up services"
if pidof -q systemd; then
	if [ -n "${restart_rabbitmq}" ] ||
	   [ -n "${restart_telegraf}" ] ||
	   [ -n "${restart_piot}" ]; then
		systemctl daemon-reload
	fi
	if [ -n "${restart_rabbitmq}" ]; then
		echo "- Restarting RabbitMQ server"
		systemctl -q restart rabbitmq-server
	fi
	if [ -n "${restart_telegraf}" ]; then
		echo "- Restarting telegraf"
		systemctl -q restart telegraf
	fi
	if [ -n "${restart_piot}" ]; then
		echo "- Restarting piot and piot-update.timer"
		systemctl -q restart piot piot-update.timer
	fi
fi
for unit in rabbitmq-server telegraf piot piot-update.timer; do
	if ! systemctl -q is-enabled "${unit}"; then
		echo "- Enabling ${unit}"
		systemctl -q enable "${unit}"
	fi
	if pidof -q systemd && ! systemctl -q is-active "${unit}"; then
		echo "- Starting ${unit}"
		systemctl -q restart "${unit}"
	fi
done

echo "[$(date -Ins)] Finished"
