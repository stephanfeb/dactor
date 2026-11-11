# A dactor node for the NAT harness. Build context: the dactor repository
# root (see compose.yml).

FROM dart:3.11.5 AS build
WORKDIR /src
COPY pubspec.yaml ./
COPY lib lib
COPY packages/dactor_remote packages/dactor_remote
COPY packages/dactor_libp2p packages/dactor_libp2p
WORKDIR /src/packages/dactor_libp2p
RUN dart pub get
RUN mkdir -p /out && dart compile exe test/nat/nat_node.dart -o /out/nat_node

FROM debian:bookworm-slim
# iproute2: the node routes the simulated internet through its NAT router.
RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/nat_node /usr/local/bin/nat_node
COPY packages/dactor_libp2p/test/nat/node-entrypoint.sh /usr/local/bin/node-entrypoint.sh
RUN chmod +x /usr/local/bin/node-entrypoint.sh
ENTRYPOINT ["node-entrypoint.sh"]
