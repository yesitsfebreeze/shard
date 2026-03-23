default: build

set shell         := ["bash", "-cu"]
set windows-shell := ["bash", "-cu"]

image := "shard-int"
key   := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

build:
	docker build -f scripts/Dockerfile.integration -t {{image}} .

test: build
	docker run --rm {{image}}

app:
	cd app && npx vite
