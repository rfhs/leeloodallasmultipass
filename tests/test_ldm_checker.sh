#!/bin/sh
# Tests ldm_checker without radios, in a throwaway container: dummy
# unified_client processes, an ldm.conf, configs and status files with chosen
# mtimes, with the checker and the cases run under each shell given with -s
# ("sh" runs the checker as its #! says).
#   ./tests/test_ldm_checker.sh [-s shell]... [-c checker] [-i image]
#   ./tests/test_ldm_checker.sh -s bash -s dash -s mksh -s 'busybox ash'
# The image is Debian based; procps, mksh and busybox are installed in it.
set -eu

checker=ldm_checker
image=debian:trixie-slim
shells=""
while getopts s:c:i: opt; do
  case "${opt}" in
    s) shells="${shells}${OPTARG}
";;
    c) checker="${OPTARG}";;
    i) image="${OPTARG}";;
    *) exit 2;;
  esac
done
if [ -z "${shells}" ]; then
  shells="sh
"
fi
case "${checker}" in
  /*) ;;
  *) checker="${PWD}/${checker}";;
esac
cd "$(dirname "${0}")/.."

c="ldm-checker-test-$$"
docker run -d --rm --name "${c}" "${image}" sleep infinity > /dev/null
trap 'docker rm -f "${c}" > /dev/null 2>&1 || true' EXIT
docker exec "${c}" sh -c 'apt-get update -qq > /dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends procps mksh busybox > /dev/null'
docker exec -i "${c}" sh -c 'cat > /ldm_checker && chmod +x /ldm_checker' < "${checker}"

docker exec -i "${c}" sh -c 'cat > /test.sh' < tests/ldm_checker_cases.sh

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
