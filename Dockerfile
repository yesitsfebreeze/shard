FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    python3 \
    ca-certificates \
    unzip \
    clang \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Download shard binary (Linux amd64) — always fetch latest nightly, never cache
ADD "https://api.github.com/repos/yesitsfebreeze/shard/releases/tags/main" /dev/null
RUN curl -fsSL https://github.com/yesitsfebreeze/shard/releases/download/main/shard-linux-amd64.tar.gz -o shard.tar.gz && \
    tar xzf shard.tar.gz && \
    rm shard.tar.gz && \
    mv shard /usr/local/bin/shard && \
    chmod +x /usr/local/bin/shard

# Install Odin compiler (same version as CI)
RUN mkdir -p /opt/odin-sdk && \
    curl -fsSL https://github.com/odin-lang/Odin/releases/download/dev-2026-02/odin-linux-amd64-dev-2026-02.tar.gz -o odin.tar.gz && \
    tar xzf odin.tar.gz -C /opt/odin-sdk && \
    rm odin.tar.gz && \
    ODIN_DIR=$(find /opt/odin-sdk -type f -name odin | head -1 | xargs dirname) && \
    ln -s "$ODIN_DIR/odin" /usr/local/bin/odin

# Copy source and build — overwrites the downloaded binary with our local build
COPY src/ /build/src/
RUN odin build /build/src -out:/usr/local/bin/shard -o:speed && \
    chmod +x /usr/local/bin/shard

COPY server.py /app/server.py

WORKDIR /data

EXPOSE 8080

CMD ["python3", "/app/server.py"]
