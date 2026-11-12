#!/bin/sh
# Routes the simulated internet through this home network's NAT router,
# waits for the relay's address, then runs the node with the arguments
# given.
set -e

ip route replace "$PUBLIC_NET" via "$NAT_GATEWAY"

while [ ! -s /shared/server.addr ]; do sleep 0.5; done

exec nat_node "$@"
