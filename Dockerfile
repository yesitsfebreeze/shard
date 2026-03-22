FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates unzip clang \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/odin-sdk && \
    curl -fsSL https://github.com/odin-lang/Odin/releases/download/dev-2026-02/odin-linux-amd64-dev-2026-02.tar.gz -o odin.tar.gz && \
    tar xzf odin.tar.gz -C /opt/odin-sdk && \
    rm odin.tar.gz && \
    ODIN_DIR=$(find /opt/odin-sdk -type f -name odin | head -1 | xargs dirname) && \
    ln -s "$ODIN_DIR/odin" /usr/local/bin/odin

WORKDIR /build
COPY *.odin /build/
COPY help/ /build/help/

RUN mkdir -p /app && odin build /build -out:/app/shard -o:speed -vet -strict-style -debug

WORKDIR /app
COPY test.sh /app/
RUN chmod +x /app/test.sh

CMD ["/app/test.sh"]
