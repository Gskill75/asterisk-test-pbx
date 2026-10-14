#!/bin/sh
#
# run.sh
#
# Pre-answer test, run in the sipp container of compose.yml, which shares the
# network namespace of the test PBX. With PBX_PREANSWER yes or no, it
# registers the extension 100, has the simulated carrier (127.0.0.2) call the
# trunk while capturing the SIP and RTP exchanged, and checks what the carrier
# got before the call was answered:
#   yes: 183 with SDP, no 180, RTP during the music and the in-band ringing
#   no:  180 without SDP, no 183, no RTP
# The capture is kept in out/preanswer-$PBX_PREANSWER.pcap.
#

PBX_PREANSWER=${PBX_PREANSWER-yes}
case $PBX_PREANSWER in
yes) scenario=carrier_183.xml ;;
no)  scenario=carrier_180.xml ;;
*)   echo "PBX_PREANSWER must be yes or no, not '$PBX_PREANSWER'."; exit 2 ;;
esac

out=/out/preanswer-$PBX_PREANSWER
sipp_opt="-nostdin -timeout 40 -timeout_error -trace_err -error_file $out-sipp.log"
rm -f $out*

tcpdump -i lo -U -w $out.pcap udp 2>/dev/null &
dump_pid=$!
sleep 1

echo "Registering extension 100."
sipp 127.0.0.1:5060 -sf /test/phone_register.xml -i 127.0.0.1 -p 5080 \
	-au 100 -ap test -m 1 $sipp_opt >/dev/null || {
	echo "FAIL: extension 100 could not register, see $out-sipp.log."
	kill $dump_pid; exit 1; }

sipp -sf /test/phone_answer.xml -i 127.0.0.1 -p 5080 -mi 127.0.0.1 -mp 6100 \
	$sipp_opt >/dev/null &
phone_pid=$!
sleep 1

echo "Carrier calling the trunk, PBX_PREANSWER=$PBX_PREANSWER."
sipp 127.0.0.1:5070 -sf /test/$scenario -s 0100000000 -i 127.0.0.2 -p 5090 \
	-mi 127.0.0.2 -mp 6000 -m 1 $sipp_opt >/dev/null
sipp_rc=$?

sleep 1
kill $phone_pid $dump_pid 2>/dev/null
wait 2>/dev/null

# Classify the captured packets: SIP responses to the carrier, INVITE to the
# extension, and RTP to the carrier before the call is answered, during the
# music (before the extension is dialed) and during the ringing.
tcpdump -tt -nn -A -r $out.pcap 2>/dev/null | awk -v mode=$PBX_PREANSWER -v rc=$sipp_rc '
/^[0-9]+\.[0-9]+ IP / {
	t = $1; src = $3; dst = $5; sub(/:$/, "", dst); cur = ""
	if (src == "127.0.0.1.5070" && dst == "127.0.0.2.5090") cur = "carrier"
	if (dst == "127.0.0.1.5080") cur = "phone"
	if (dst == "127.0.0.2.6000" && !answered) {
		if (!first_rtp) first_rtp = t
		if (dialed) ring++; else music++
	}
	next
}
cur == "carrier" && match($0, /SIP\/2\.0 [1-6][0-9][0-9] /) {
	code = substr($0, RSTART + 8, 3); cur = ""
	if (!answered) {
		resp = resp " " code; got[code]++
		if (code == "200") answered = t
	}
}
cur == "phone" && /INVITE sip:/ { if (!dialed) dialed = t; cur = "" }
function check(ok, what) { printf "%-4s %s\n", ok ? "ok" : "FAIL", what; if (!ok) failed = 1 }
END {
	printf "Carrier got before answer:%s\n", resp
	printf "RTP to carrier before answer: %d packets during the music, %d during the ringing\n", music, ring
	if (first_rtp && dialed) printf "Music played for %.1f s, extension rang for %.1f s\n", dialed - first_rtp, answered - dialed
	check(rc == 0, "SIPp scenario, see the sipp log for the SIP messages")
	check(answered, "call answered by the extension")
	if (mode == "yes") {
		check(got["183"], "183 Session Progress with SDP")
		check(!got["180"], "no 180 Ringing")
		check(music >= 100, "pre-answer music as early media, at least 2 s")
		check(ring >= 50, "in-band ringing as early media, at least 1 s")
	} else {
		check(got["180"], "180 Ringing without SDP")
		check(!got["183"], "no 183 Session Progress")
		check(music + ring == 0, "no early media")
	}
	print failed ? "FAILED" : "PASSED"
	exit failed
}'
