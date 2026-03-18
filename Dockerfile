FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    unzip \
    clang \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Odin compiler (same version as CI)
RUN mkdir -p /opt/odin-sdk && \
    curl -fsSL https://github.com/odin-lang/Odin/releases/download/dev-2026-02/odin-linux-amd64-dev-2026-02.tar.gz -o odin.tar.gz && \
    tar xzf odin.tar.gz -C /opt/odin-sdk && \
    rm odin.tar.gz && \
    ODIN_DIR=$(find /opt/odin-sdk -type f -name odin | head -1 | xargs dirname) && \
    ln -s "$ODIN_DIR/odin" /usr/local/bin/odin

# Copy source and build
COPY src/ /build/src/
RUN odin build /build/src -out:/usr/local/bin/shard -o:speed && \
    chmod +x /usr/local/bin/shard

# entrypoint: start daemon then serve HTTP MCP on $PORT (default 8080)
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

WORKDIR /data

EXPOSE 8080

CMD ["/app/docker-entrypoint.sh"]
