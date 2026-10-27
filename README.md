# leeloodallasmultipass
Client scripts for creating wifi clients for the RF CTF

Dependencies:
There are a bunch, and ldm will toss errors if you don't have them.

Instructions:
Run ./ldm

Health check:
`ldm_checker` checks that every client in ldm.conf is running and has tried to connect, and, without `--test`, connected, recently enough; it writes the result to `/root/shared_persistent_storage/Client_status`. rfctf-client runs it as its docker healthcheck.

Tests:
`tests/test_ldm_checker.sh` tests `ldm_checker` without radios, in a throwaway Debian container (it needs docker): dummy unified_client processes, an ldm.conf, configs and status files with chosen ages. `-s` picks the shell to run the checker and the cases under, and can be given more than once; `-c` tests another checker, e.g. an older one.

    ./tests/test_ldm_checker.sh
    ./tests/test_ldm_checker.sh -s bash -s dash -s mksh -s 'busybox ash'

It prints PASS or FAIL for each case and exits 1 if any failed. GitHub Actions (`.github/workflows/test.yml`) runs ShellCheck on every shell script and the test under bash, dash, mksh and busybox ash.
