#!/bin/sh
#
# capture.sh
#
# Capture the SIP and RTP traffic of the PBX, whose network namespace this
# container shares, in a new file every CAPTURE_ROTATE seconds, keeping the
# CAPTURE_KEEP most recent ones. Then serve them, along with the test bench
# captures, on CAPTURE_PORT.
#

: "${CAPTURE_DIR:=/captures}" "${CAPTURE_ROTATE:=900}" "${CAPTURE_KEEP:=48}"
: "${CAPTURE_FILTER:=udp or tcp port 5060}" "${CAPTURE_PORT:=8080}"
export CAPTURE_DIR CAPTURE_KEEP CAPTURE_PORT

mkdir -p "$CAPTURE_DIR"
# -U: packet buffered, so the file being written can be downloaded anytime.
tcpdump -i any -n -U -s 0 -Z root -G "$CAPTURE_ROTATE" \
	-w "$CAPTURE_DIR/pbx-%Y%m%d-%H%M%S.pcap" $CAPTURE_FILTER &

exec python3 /usr/local/bin/server.py
