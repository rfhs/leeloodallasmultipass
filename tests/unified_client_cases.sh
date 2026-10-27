#!/bin/sh
# The cases test_unified_client.sh runs in its container, as root, with
# unified_client in /unified_client:
#   sh unified_client_cases.sh shell
shell="${1}"
missing_tools=""
for tool in awk bash chmod cp grep ip kill mkdir pgrep pkill rm sed sleep wc; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
fi

work=/root/leeloodallasmultipass
iface=wlan10
gateway=192.168.42.1
log=/tmp/client.log

# Stand-ins. wpa_supplicant brings the interface up, so it has carrier, as an
# association would; dhcpcd gives it an address and a default route and then
# titles itself as dhcpcd 10 does; arping logs its arguments, or with no
# address fails at once, as arping does. With
# STUB_STRAY=1 one ignores TERM and leaves the interface alone, as a stray left
# by an earlier run that has to be killed with -9. iw reports the interface
# connected while it has carrier.
cat > /usr/local/bin/wpa_supplicant << 'EOF'
#!/bin/sh
if [ -n "${STUB_STRAY:-}" ]; then
  trap '' TERM
else
  ip link set "${3}" up
fi
while :; do sleep 1; done
EOF
cat > /usr/local/bin/dhcpcd << 'EOF'
#!/bin/bash
for arg in "$@"; do
  case "${arg}" in
    -*) ;;
    *) iface="${arg}";;
  esac
done
if [ -n "${STUB_STRAY:-}" ]; then
  trap '' TERM
else
  ip addr add 192.168.42.2/24 dev "${iface}"
  ip route add default via 192.168.42.1 dev "${iface}" metric 100
fi
exec -a "dhcpcd: ${iface} [ip4]" sleep 1000
EOF
cat > /usr/bin/arping << 'EOF'
#!/bin/sh
if [ -n "${STUB_STRAY:-}" ]; then
  trap '' TERM
  while :; do sleep 1; done
fi
for target in "$@"; do :; done
if [ -z "${target}" ]; then
  exit 2
fi
printf '%s\n' "$*" >> /tmp/arping.log
sleep 1
EOF
cat > /usr/local/bin/iw << 'EOF'
#!/bin/sh
if [ "$(cat "/sys/class/net/${1}/carrier" 2> /dev/null)" = 1 ]; then
  printf 'Connected to 02:00:00:00:00:00 (on %s)\n' "${1}"
else
  printf 'Not connected.\n'
fi
EOF
chmod +x /usr/local/bin/wpa_supplicant /usr/local/bin/dhcpcd /usr/bin/arping /usr/local/bin/iw

kill_stubs() {
  pkill -9 -f '/usr/local/bin/wpa_supplicant|^dhcpcd: |/usr/bin/arping' || true
}

stop_client() {
  if [ -n "${client:-}" ]; then
    kill -TERM "${client}" 2> /dev/null || true
    wait_for 10 gone "${client}" || kill -9 "${client}" 2> /dev/null || true
    client=""
  fi
}

# reset [link]: no client or stubs running, and a fresh work dir and status
# dir; with link, a dummy interface for wlan10, down
reset() {
  stop_client
  kill_stubs
  ip link del "${iface}" 2> /dev/null || true
  rm -rf "${work}" /run/rfctf_status /tmp/arping.log "${log}"
  mkdir -p "${work}/config" /run/rfctf_status
  cp /unified_client "${work}/unified_client"
  printf 'network={\n\tssid="RFHS_TEST"\n\tpsk="only a test"\n}\n' > "${work}/config/RFHS_TEST.conf"
  if [ "${1:-}" = link ]; then
    ip link add "${iface}" type dummy
  fi
}

# start timeout: starts unified_client on wlan10 with the config
start() {
  cd "${work}" || exit 1
  if [ "${shell}" = sh ]; then
    ./unified_client "${iface}" "${1}" RFHS_TEST.conf > "${log}" 2>&1 &
  else
    # shellcheck disable=SC2086
    ${shell} ./unified_client "${iface}" "${1}" RFHS_TEST.conf > "${log}" 2>&1 &
  fi
  client=$!
  cd / || exit 1
}

# wait_for seconds command...: runs the command every 0.1 s until it succeeds
wait_for() {
  tries=$((${1} * 10))
  shift
  while ! "$@"; do
    tries=$((tries - 1))
    if [ "${tries}" -le 0 ]; then
      return 1
    fi
    sleep 0.1
  done
}

# shellcheck disable=SC2329 # wait_for runs it
arpinged() {
  [ -f /tmp/arping.log ] && grep -qx -- "-c 5 -w 5 -I ${iface} ${gateway}" /tmp/arping.log
}
# gone pid: the process has exited; one of this shell's children stays a
# zombie until the shell reaps it, which some shells only do when they wait
# shellcheck disable=SC2329 # wait_for runs it
gone() {
  state="$(awk '{ print $3 }' "/proc/${1}/stat" 2> /dev/null)"
  [ -z "${state}" ] || [ "${state}" = Z ]
}
# arpings_over lines: the arping log has more than that many lines
arpings_over() {
  [ "$(wc -l < /tmp/arping.log)" -gt "${1}" ]
}
# cpu: the client's CPU so far in clock ticks, its children's included
cpu() {
  awk '{ print $14 + $15 + $16 + $17 }' "/proc/${client}/stat"
}

failures=0
result() {
  if [ "${1}" = 0 ]; then
    printf 'PASS: [%s] %s\n' "${shell}" "${2}"
  else
    printf 'FAIL: [%s] %s; its output:\n' "${shell}" "${2}"
    sed 's/^/    /' "${log}"
    failures=$((failures + 1))
  fi
}

reset
start 60
sleep 2
grep -qx "Waiting for ${iface}..." "${log}" && ! grep -q 'Attempting' "${log}"
result $? 'waits for its interface'
ip link add "${iface}" type dummy
wait_for 15 arpinged && [ -f /run/rfctf_status/RFHS_TEST_attempt ] \
  && wait_for 2 grep -qsx '192.168.42.2/24' /run/rfctf_status/RFHS_TEST_active \
  && ! grep -qi -e 'invalid' -e 'error' -e 'not found' "${log}"
result $? 'then connects once the interface is up, arpings the gateway and writes its address to the status file'

ip route del default dev "${iface}"
before="$(cpu)"
lines="$(wc -l < /tmp/arping.log)"
sleep 3
spent=$(($(cpu) - before))
[ "${spent}" -lt 30 ] && ! arpings_over $((lines + 1))
result $? "with no gateway it waits instead of spinning (${spent} ticks in 3 s)"
ip route add default via "${gateway}" dev "${iface}" metric 100
lines="$(wc -l < /tmp/arping.log)"
wait_for 5 arpings_over "${lines}"
result $? 'and arpings again once the gateway is back'

reset
exit "${failures}"
