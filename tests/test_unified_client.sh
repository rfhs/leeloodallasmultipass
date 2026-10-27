#!/bin/sh
# Tests unified_client without radios, in a throwaway container: a dummy
# interface for wlan10 and stand-ins for wpa_supplicant (brings the interface
# up, so it has carrier), dhcpcd (gives it an address and a default route and
# titles itself as dhcpcd does) and arping (logs its arguments), with
# unified_client and the cases run under each shell given with -s ("sh" runs
# unified_client as its #! says). The container needs NET_ADMIN, so the host
# needs the dummy module.
#   ./tests/test_unified_client.sh [-s shell]... [-u unified_client] [-i image]
#   ./tests/test_unified_client.sh -s bash -s dash -s mksh -s 'busybox ash'
# The image is Debian based; procps, iproute2, mksh and busybox are installed
# in it.
set -eu

missing_tools=""
for tool in dirname docker; do
  command -v "${tool}" > /dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
if [ -n "${missing_tools}" ]; then
  printf '%s: required commands not found:%s\n' "${0##*/}" "${missing_tools}" >&2
  exit 1
fi

client=unified_client
image=debian:trixie-slim
shells=""
while getopts s:u:i: opt; do
  case "${opt}" in
    s) shells="${shells}${OPTARG}
";;
    u) client="${OPTARG}";;
    i) image="${OPTARG}";;
    *) exit 2;;
  esac
done
if [ -z "${shells}" ]; then
  shells="sh
"
fi
case "${client}" in
  /*) ;;
  *) client="${PWD}/${client}";;
esac
cd "$(dirname "${0}")/.."

c="unified-client-test-$$"
docker run -d --rm --cap-add NET_ADMIN --name "${c}" "${image}" sleep infinity > /dev/null
trap 'docker rm -f "${c}" > /dev/null 2>&1 || true' EXIT
docker exec "${c}" sh -c 'apt-get update -qq > /dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends procps iproute2 mksh busybox > /dev/null'
docker exec -i "${c}" sh -c 'cat > /unified_client && chmod +x /unified_client' < "${client}"

docker exec -i "${c}" sh -c 'cat > /test.sh' < tests/unified_client_cases.sh

failures=0
while IFS= read -r shell; do
  if [ -z "${shell}" ]; then
    continue
  fi
  # shellcheck disable=SC2086
  docker exec "${c}" ${shell} /test.sh "${shell}" || failures=$((failures + $?))
done << EOF
${shells}
EOF
if [ "${failures}" -ne 0 ]; then
  printf '%s check(s) failed\n' "${failures}"
  exit 1
fi
