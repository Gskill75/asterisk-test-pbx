#!/bin/sh
#
# entrypoint.sh
#
# Copy the configuration from /config to /etc/asterisk, replacing the @VAR@
# placeholders with the value of the environment variable VAR, then run
# Asterisk in the foreground. Done at every start, so a restart applies the
# changes made to ./config or .env.
#
# The SIP trunk configuration is dropped when TRUNK_HOST is empty, its
# outbound proxy when TRUNK_PROXY is empty. TRUNK_EXTERNAL_IP=auto is replaced
# by the public address, detected with api.ipify.org.
#

set -eu

log() { echo "entrypoint: $*" >&2; }

: "${PBX_EXTERNAL_IP:=127.0.0.1}" "${PBX_PREANSWER:=no}" "${INBOUND_EXTEN:=100}"
: "${TRUNK_HOST:=}" "${TRUNK_USER:=}" "${TRUNK_PASSWORD:=}" "${TRUNK_PROXY:=}"
: "${TRUNK_EXTERNAL_IP:=}"
export PBX_EXTERNAL_IP PBX_PREANSWER INBOUND_EXTEN TRUNK_HOST TRUNK_USER \
	TRUNK_PASSWORD TRUNK_PROXY TRUNK_EXTERNAL_IP

case $PBX_PREANSWER in
yes|no) ;;
*) log "PBX_PREANSWER must be yes or no, not '$PBX_PREANSWER'."; exit 1 ;;
esac

# Asterisk ignores TZ and reads /etc/localtime
if [ -n "${TZ-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
	ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
fi

conf=/etc/asterisk
rm -f $conf/*.conf
cp /config/*.conf $conf/

if [ -z "$TRUNK_HOST" ]; then
	log "TRUNK_HOST is empty, no SIP trunk."
	rm -f $conf/pjsip_trunk.conf
elif [ -z "$TRUNK_PROXY" ]; then
	sed -i '/@TRUNK_PROXY@/d' $conf/pjsip_trunk.conf
fi

if [ "$TRUNK_EXTERNAL_IP" = auto ]; then
	TRUNK_EXTERNAL_IP=
	# The network might not be ready yet, so retry for a while
	for try in 1 2 3 4 5 6 7 8 9 10; do
		TRUNK_EXTERNAL_IP=$(curl -fsS -m 3 https://api.ipify.org) && break
		sleep 2
	done
	log "Public address: ${TRUNK_EXTERNAL_IP:-not detected}."
fi
[ -n "$TRUNK_EXTERNAL_IP" ] || sed -i '/@TRUNK_EXTERNAL_IP@/d' $conf/pjsip.conf

for file in $conf/*.conf; do
	for var in $(grep -o '@[A-Z][A-Z0-9_]*@' "$file" | sort -u | tr -d @); do
		eval "val=\${$var-}"
		[ -n "$val" ] || log "No value for @$var@ in $file."
		# Escape the sed replacement special characters: \ & |
		val=$(printf '%s' "$val" | sed 's/[\\&|]/\\&/g')
		sed -i "s|@$var@|$val|g" "$file"
	done
done
chown -R asterisk:asterisk $conf

exec asterisk -f -U asterisk -G asterisk "$@"
