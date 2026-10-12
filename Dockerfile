# syntax=docker/dockerfile:1.7

ARG UBUNTU_VERSION=22.04

FROM ubuntu:${UBUNTU_VERSION} AS runtime-base

ARG DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libcurl4:i386 \
        libgcc-s1:i386 \
        libstdc++6:i386 \
        netcat-openbsd \
        zlib1g:i386 \
    && rm -rf /var/lib/apt/lists/*

FROM runtime-base AS byond

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        make \
        unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/byond

COPY dependencies.sh /tmp/dependencies.sh
COPY docker/vendor/516.1688_byond_linux.zip /opt/byond/byond.zip

RUN set -eux; \
    echo '16278f318cdeb4b77c57868dd7135032fde717ea6226269d22b2a1a50968e7f9  byond.zip' | sha256sum -c -; \
    sed -i 's/\r$//' /tmp/dependencies.sh; \
    . /tmp/dependencies.sh; \
    unzip -q byond.zip; \
    rm byond.zip; \
    cd byond; \
    make here; \
    rm /tmp/dependencies.sh

ENV BYOND_HOME=/opt/byond/byond
ENV PATH="${BYOND_HOME}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${BYOND_HOME}/bin"

FROM byond AS build

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY . .

RUN find . -type f -name '*.sh' -exec sed -i 's/\r$//' {} + \
    && sed -i 's/\r$//' \
        tools/build/build \
        tools/bootstrap/node \
        tools/bootstrap/python \
        tools/deploy.sh \
    && chmod 0755 \
        tools/build/build \
        tools/bootstrap/node \
        tools/bootstrap/python \
        tools/deploy.sh

RUN --mount=type=cache,target=/var/cache/reno-bootstrap \
    TG_BOOTSTRAP_NODE_LINUX=1 \
    TG_BOOTSTRAP_CACHE=/var/cache/reno-bootstrap \
    tools/build/build \
    && tools/deploy.sh /deploy

FROM runtime-base AS native-libs

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY dependencies.sh /tmp/dependencies.sh

RUN set -eux; \
    sed -i 's/\r$//' /tmp/dependencies.sh; \
    . /tmp/dependencies.sh; \
    mkdir -p /native; \
    curl --fail --location --retry 5 --retry-delay 2 \
        "https://github.com/tgstation/rust-g/releases/download/${RUST_G_VERSION}/librust_g.so" \
        --output /native/librust_g.so; \
    chmod 0755 /native/librust_g.so; \
    rm /tmp/dependencies.sh

FROM runtime-base AS final

ENV BYOND_HOME=/opt/byond/byond
ENV PATH="${BYOND_HOME}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${BYOND_HOME}/bin"
ENV PORT=54321
ENV DMB=fortune13.dmb
ENV BYOND_TRUSTED=1

WORKDIR /opt/reno

RUN groupadd --gid 10001 byond \
    && useradd \
        --uid 10001 \
        --gid 10001 \
        --home-dir /opt/reno \
        --shell /usr/sbin/nologin \
        byond \
    && mkdir -p /opt/reno/config /opt/reno/data \
    && chown -R 10001:10001 /opt/reno

COPY --from=byond /opt/byond/byond /opt/byond/byond
COPY --from=build --chown=10001:10001 /deploy/ /opt/reno/
COPY --from=native-libs --chown=10001:10001 /native/librust_g.so /opt/reno/librust_g.so
COPY --chown=10001:10001 config/maps.txt /opt/reno/config-defaults/maps.txt
COPY docker/entrypoint.sh /usr/local/bin/reno-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/reno-healthcheck

RUN sed -i 's/\r$//' /usr/local/bin/reno-entrypoint \
    && sed -i 's/\r$//' /usr/local/bin/reno-healthcheck \
    && chmod 0755 /usr/local/bin/reno-entrypoint /usr/local/bin/reno-healthcheck \
    && if ldd /opt/reno/librust_g.so | grep -q "not found"; then exit 1; fi

VOLUME ["/opt/reno/config", "/opt/reno/data"]

EXPOSE 54321/tcp

STOPSIGNAL SIGTERM

USER 10001:10001

HEALTHCHECK --interval=30s --timeout=5s --start-period=5m --retries=3 \
    CMD /usr/local/bin/reno-healthcheck

ENTRYPOINT ["/usr/local/bin/reno-entrypoint"]
