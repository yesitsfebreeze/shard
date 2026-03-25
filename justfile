default: build

set shell         := ["bash", "-cu"]
set windows-shell := ["bash", "-cu"]

image := "shard"
shards := ".shards"

build:
	docker build -t {{image}} .

# Install fresh binary into .shards/bin (loses appended data)
install: build
	mkdir -p {{shards}}/bin {{shards}}/shards {{shards}}/cache
	docker create --name shard-tmp {{image}} echo
	docker cp shard-tmp:/root/.shards/bin/shard {{shards}}/bin/shard
	docker rm shard-tmp

# Run daemon with persistent .shards bind mount
run:
	docker run --rm -d -p 8080:8080 --name shard -v "$(pwd)/{{shards}}:/root/.shards" {{image}} --daemon

stop:
	docker stop shard 2>/dev/null || true

# Build, install fresh binary, and run (clean start)
clean: install run

test: build
	docker run --rm {{image}}

up: build
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

restart: build
	docker compose down
	docker compose up -d

build-linux:
	odin build . -out:.shards/bin/shard -o:speed -vet -strict-style

build-mac:
	odin build . -out:shard -target:darwin_arm64 -o:speed -vet -strict-style

build-mac-x86:
	odin build . -out:shard -target:darwin_amd64 -o:speed -vet -strict-style

build-windows:
	odin build . -out:shard.exe -target:windows_amd64 -o:speed -vet -strict-style
