#!/bin/sh
# The cases test_ldm_checker.sh runs in its container, as root, with the
# checker in /ldm_checker:
#   sh ldm_checker_cases.sh shell
shell="${1}"
missing_tools=""
for tool in cat chmod cmp date grep mkdir pgrep pkill rm sed sleep touch wc; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
fi

work=/root/leeloodallasmultipass
status=/root/shared_persistent_storage/Client_status

# Stand-ins for the tools ldm_checker --test requires of ldm and unified_client
stubs="arping screen dhcpcd ip wpa_supplicant"
for tool in ${stubs}; do
  printf '#!/bin/sh\n' > "/usr/local/bin/${tool}"
  chmod +x "/usr/local/bin/${tool}"
done
# For --excessive: ip fails with IP_FAILS set, and dhcpcd logs that it ran and
# titles itself as dhcpcd 10 does, or with DHCPCD_PREFIX in place of
# "dhcpcd:", or with DHCPCD_EXIT set says so and exits with it
# shellcheck disable=SC2016 # it expands in the stub
printf '#!/bin/sh\n[ -z "${IP_FAILS:-}" ]\n' > /usr/local/bin/ip
cat > /usr/local/bin/dhcpcd << 'EOF'
#!/bin/bash
for arg in "$@"; do
  case "${arg}" in
    -*) ;;
    *) iface="${arg}";;
  esac
done
printf '%s\n' "$*" >> /tmp/dhcpcd.log
if [ -n "${DHCPCD_EXIT:-}" ]; then
  printf 'exiting with %s\n' "${DHCPCD_EXIT}"
  exit "${DHCPCD_EXIT}"
fi
exec -a "${DHCPCD_PREFIX:-dhcpcd:} ${iface} [ip4]" sleep 1000
EOF

start_clients() {
  grep -v '^#' ldm.conf | while read -r cmd iface timeout confs; do
    # shellcheck disable=SC2086
    "${cmd}" "${iface}" "${timeout}" ${confs} > /dev/null 2>&1 &
  done
}

stop_clients() {
  pkill -f '^/bin/sh ./unified_client' || true
  while pgrep -f '^/bin/sh ./unified_client' > /dev/null; do
    sleep 0.1
  done
}

config() {
  printf '# Only WPA-PSK is used.\nnetwork={\n%s\tssid="%s"\n\tpsk="only a test"\n\tpriority=1\n}\n' "${2:-}" "${1}" > "config/${1}.conf"
}

# age file seconds: sets the file's mtime that long ago
age() {
  touch -d "@$(($(date +%s) - ${2}))" "${1}"
}

reset() {
  stop_clients
  rm -rf "${work}" /run/rfctf_status /root/shared_persistent_storage /tmp/dhcpcd.log
  mkdir -p "${work}/config" /run/rfctf_status
  cd "${work}" || exit 1
  printf '#!/bin/sh\nwhile :; do sleep 1000; done\n' > unified_client
  chmod +x unified_client
  cat > ldm.conf << 'CONF'
# This file holds the commands which ldm then runs for you in a screen session
#./unified_client wlanX time_between_reconnects wpa_supplicant.conf
./unified_client wlan10 300 RFHS_A.conf
./unified_client wlan11 100 RFHS_B.conf RFHS_C.conf
./unified_client wlan12 300 RFHS_RFCTF_00.conf
CONF
  for ssid in RFHS_A RFHS_B RFHS_C RFHS_RFCTF_00; do
    config "${ssid}"
    touch "/run/rfctf_status/${ssid}_attempt" "/run/rfctf_status/${ssid}_active"
  done
  start_clients
}

# check [--test]: runs the checker, sets rc and leaves its output in /tmp/out
check() {
  if [ "${shell}" = sh ]; then
    /ldm_checker "$@" > /tmp/out 2>&1 && rc=0 || rc=$?
  else
    # shellcheck disable=SC2086
    ${shell} /ldm_checker "$@" > /tmp/out 2>&1 && rc=0 || rc=$?
  fi
}

failures=0
result() {
  if [ "${1}" = 0 ]; then
    printf 'PASS: [%s] %s\n' "${shell}" "${2}"
  else
    printf 'FAIL: [%s] %s; exit %s, output:\n' "${shell}" "${2}" "${rc}"
    sed 's/^/    /' /tmp/out
    failures=$((failures + 1))
  fi
}
# line "regex": the output has a line matching it whole
line() {
  grep -qx -- "${1}" /tmp/out
}
problems() {
  grep -c '^No ' /tmp/out || true
}
good() {
  [ "${rc}" = 0 ] && [ "$(problems)" = 0 ] && line 'Everything is operating as expected\.'
}
bad() {
  [ "${rc}" = 1 ] && line 'Something is not operating as expected\.'
}

reset
check
good && [ -d /root/shared_persistent_storage ] \
  && cmp -s /tmp/out "${status}" && [ "$(wc -l < "${status}")" = 3 ] \
  && sed -n 1p "${status}" | grep -qx '# This file is auto generated once per minute (ideally) and NEVER read by anything' \
  && sed -n 2p "${status}" | grep -qx '# Last generation start time .* (compare to "date" command)'
result $? 'everything up passes, makes the status dir and writes the header and the result to Client_status'
check --test
good
result $? 'everything up passes with --test'

reset
pkill -f '^/bin/sh ./unified_client wlan10 ' || true
sleep 0.2
check
bad && line 'No unified_client running for configured RFHS_A\.conf' && [ "$(problems)" = 1 ] \
  && cmp -s /tmp/out "${status}" && [ "$(wc -l < "${status}")" = 4 ]
result $? 'a client that is not running fails, and Client_status holds the same report'

reset
pkill -f '^/bin/sh ./unified_client wlan10 ' || true
./unified_client wlan10 30 RFHS_A.conf > /dev/null 2>&1 &
sleep 0.2
check
bad && line 'No unified_client running for configured RFHS_A\.conf'
result $? 'a client running with another timeout does not count'

reset
age /run/rfctf_status/RFHS_A_attempt 350
check
good
result $? 'an attempt within 300 s times 1 conf file plus 60 s passes'
age /run/rfctf_status/RFHS_A_attempt 400
check
bad && line 'No connection attempt on configured ssid RFHS_A in 40[0-2]s' && [ "$(problems)" = 1 ]
result $? 'an attempt older than that fails'

reset
age /run/rfctf_status/RFHS_C_attempt 250
check
good
result $? 'two conf files on a line double the timeout: an attempt 250 s ago is within 100 s times 2 plus 60 s'
age /run/rfctf_status/RFHS_C_attempt 270
check
bad && line 'No connection attempt on configured ssid RFHS_C in 27[0-2]s'
result $? 'and one 270 s ago is not'

reset
rm /run/rfctf_status/RFHS_A_attempt
check
bad && line 'No connection attempt on configured ssid RFHS_A' && [ "$(problems)" = 1 ]
result $? 'no attempt fails, and no success is not checked then'

reset
rm /run/rfctf_status/RFHS_A_active
check
bad && line 'No connection success on configured ssid RFHS_A' && [ "$(problems)" = 1 ]
result $? 'no success fails'
check --test
good
result $? 'no success passes with --test'

reset
age /run/rfctf_status/RFHS_A_active 400
check
bad && line 'No connection success on configured ssid RFHS_A in 40[0-2]s'
result $? 'a success older than the timeout fails'
check --test
good
result $? 'and passes with --test'

reset
rm /run/rfctf_status/RFHS_RFCTF_00_active
check
[ "${rc}" = 0 ] && line 'No connection success on configured ssid RFHS_RFCTF_00' \
  && line 'Everything is operating as expected\.'
result $? 'a client only SSID (RFHS_RFCTF_00) without a success is reported but passes'

reset
config RFHS_A '	bssid=02:00:00:00:00:01
'
check
good
result $? 'a bssid= line before ssid= is not the SSID, as unified_client reads it'

reset
printf '#./unified_client wlan10 999 RFHS_A.conf\n' >> ldm.conf
check
good
result $? 'a commented out line with a configured conf file is ignored'

reset
rm /usr/local/bin/wpa_supplicant
check
good
result $? 'a command unified_client needs being missing does not matter without --test'
check --test
[ "${rc}" = 1 ] && line 'ldm_checker: required commands not found: wpa_supplicant (unified_client)' \
  && cmp -s /tmp/out "${status}" && [ "$(wc -l < "${status}")" = 1 ]
result $? 'with --test it fails, names the command and the script, and writes the same to Client_status'
printf '#!/bin/sh\n' > /usr/local/bin/wpa_supplicant
chmod +x /usr/local/bin/wpa_supplicant
check --test
good
result $? 'and passes again with it back'

reset
check --test
good && [ ! -e /tmp/dhcpcd.log ]
result $? '--test starts no dhcpcd'
check --excessive
good && [ -e /tmp/dhcpcd.log ] && ! pgrep -f ldmtest > /dev/null
result $? '--excessive passes when dhcpcd titles itself as unified_client expects, and leaves no dhcpcd running'
export DHCPCD_PREFIX='dhcpcd[worker]:'
check --excessive
unset DHCPCD_PREFIX
[ "${rc}" = 1 ] && grep -q '^ldm_checker: dhcpcd did not title its process "dhcpcd: ldmtest[0-9]* \[ip4\]", which unified_client kills it by; the processes for ldmtest[0-9]*: [0-9]* dhcpcd\[worker\]: ldmtest' /tmp/out \
  && cmp -s /tmp/out "${status}" && ! pgrep -f ldmtest > /dev/null
result $? 'and fails, showing the title it used, when dhcpcd titles itself otherwise'
export DHCPCD_EXIT=3
check --excessive
unset DHCPCD_EXIT
[ "${rc}" = 1 ] && grep -q '^ldm_checker: dhcpcd did not title its process "dhcpcd: ldmtest[0-9]* \[ip4\]", which unified_client kills it by; the processes for ldmtest[0-9]*: none; the dhcpcd it started had exited with 3, and said: exiting with 3$' /tmp/out \
  && cmp -s /tmp/out "${status}"
result $? 'and fails, showing its exit status and output, when dhcpcd exits at once'
rm -f /tmp/dhcpcd.log
export IP_FAILS=1
check --excessive
unset IP_FAILS
[ "${rc}" = 1 ] && line "ldm_checker: could not add a dummy interface to check dhcpcd's process title" \
  && [ ! -e /tmp/dhcpcd.log ]
result $? 'and fails when it cannot add a dummy interface'

stop_clients
exit "${failures}"
