# leeloodallasmultipass
Client scripts for creating wifi clients for the RF CTF

Dependencies:
There are a bunch, and ldm will toss errors if you don't have them.

Instructions:
Run ./ldm

Health check:
`ldm_checker` checks that every client in ldm.conf is running and has tried to connect, and, without `--test`, connected, recently enough; it writes the result to `/root/shared_persistent_storage/Client_status`. rfctf-client runs it as its docker healthcheck. `ldm_checker --excessive` does what `--test` does and then checks, on a dummy interface, that dhcpcd still titles its process `dhcpcd: <interface> [ip4]`, which unified_client stops it by. It starts a dhcpcd and needs NET_ADMIN, so the rfctf-client build runs it, not the healthcheck.

Tests:
`tests/test_ldm_checker.sh` tests `ldm_checker` without radios, in a throwaway Debian container (it needs docker): dummy unified_client processes, an ldm.conf, configs and status files with chosen ages. `-s` picks the shell to run the checker and the cases under, and can be given more than once; `-c` tests another checker, e.g. an older one.

    ./tests/test_ldm_checker.sh
    ./tests/test_ldm_checker.sh -s bash -s dash -s mksh -s 'busybox ash'

`tests/test_unified_client.sh` tests `unified_client` without radios, the same way: a dummy interface for wlan10 (so the host needs the dummy module) and stand-ins for wpa_supplicant, dhcpcd and arping. It checks that a client waits for its interface, connects and arpings the gateway, waits rather than spinning while it has no gateway, kills stray processes that ignore TERM, and stops its wpa_supplicant and dhcpcd when it is stopped. `-s` works the same, and `-u` tests another unified_client.

    ./tests/test_unified_client.sh -s bash -s dash -s mksh -s 'busybox ash'

They print PASS or FAIL for each case and exit 1 if any failed. GitHub Actions (`.github/workflows/test.yml`) runs ShellCheck on every shell script and both tests under bash, dash, mksh and busybox ash.
