#!/bin/sh
# Two dactor nodes, each behind its own NAT router, reach each other
# through a Ricochet server's relay, in go-ricochet's mailbox example
# Docker setup. Needs a go-ricochet checkout: RICOCHET_DIR, by default next
# to the dactor checkout.
#
#   - check: ask, 5000 ordered messages, 1 MiB, and the listener asking back,
#     all through the relay with hole punching off;
#   - punch: a hole punch then gives the two a direct connection, and
#     dactor's traffic moves to it with nothing lost (the punch is expected
#     to fail with NAT_TYPE=symmetric);
#   - watch: the listener's container is killed, and the dialer notices
#     through the keep-alive.
#
# CHECKS picks some of them (default "check punch watch"); LOG=name,name
# prints those libp2p loggers from both nodes, for example
# LOG=p2p-holepunch.
#
# Exits non-zero when a check fails.
set -e
CHECKS=${CHECKS:-check punch watch}
wants() { case " $CHECKS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
cd "$(dirname "$0")"
DACTOR_DIR=$(cd ../../../.. && pwd)
RICOCHET_DIR=${RICOCHET_DIR:-$(cd "$DACTOR_DIR/.." && pwd)/go-ricochet}
export DACTOR_DIR
MAILBOX="$RICOCHET_DIR/examples/mailbox/docker"
[ -f "$MAILBOX/compose.yml" ] || { echo "No go-ricochet at $RICOCHET_DIR"; exit 1; }
c() {
    docker compose --project-name dactor-nat --project-directory "$MAILBOX" \
        -f "$MAILBOX/compose.yml" -f "$PWD/compose.yml" "$@"
}
trap 'c down --remove-orphans --volumes >/dev/null 2>&1' EXIT

listener_line() {
    c logs --no-log-prefix listener | awk -v k="$1" '$1 == k {print $2}'
}

# start_listener 0|1: a fresh listener, hole punching off or on.
start_listener() {
    PUNCH=$1 c up -d --force-recreate listener
    n=0
    until ADDR=$(listener_line ADDR) && [ -n "$ADDR" ]; do
        n=$((n + 1))
        if [ $n -gt 90 ]; then c logs listener; echo "listener got no relay slot"; exit 1; fi
        sleep 1
    done
    URI=$(listener_line URI)
    echo "listener at $ADDR"
}

echo "== Starting PostgreSQL, the Ricochet server, the NAT routers (${NAT_TYPE:-cone})"
c up -d --build --wait server nat-a nat-b
c build -q listener dialer

if wants check; then
echo
echo "== check: through the relay"
start_listener 0
c run --rm -T dialer check "$ADDR" "$URI"
fi

if wants punch; then
echo
echo "== punch: through the relay, then directly"
start_listener 1
if ! c run --rm -T dialer punch "$ADDR" "$URI"; then
    PUNCH_FAILED=1
    echo "(hole punch failed)"
    [ -z "$LOG" ] || { echo "-- listener:"; c logs --no-log-prefix listener | tail -60; }
fi
fi

if wants watch; then
echo
echo "== watch: the listener's container is killed"
start_listener 0
c run --rm -T dialer watch "$ADDR" "$URI" > watch.log 2>&1 &
WATCHER=$!
until grep -q WATCHING watch.log 2>/dev/null; do
    if ! kill -0 $WATCHER 2>/dev/null; then cat watch.log; exit 1; fi
    sleep 0.5
done
c kill listener >/dev/null
echo "listener killed at $(date +%T)"
wait $WATCHER || { cat watch.log; rm -f watch.log; exit 1; }
grep -v '^\s*$' watch.log | tail -2
rm -f watch.log
fi

echo
if [ -n "$PUNCH_FAILED" ]; then
    echo "The other checks passed; the hole punch failed."
    [ "${NAT_TYPE:-cone}" = symmetric ] || exit 1
else
    echo "All checks passed."
fi
