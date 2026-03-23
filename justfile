default: build

set shell         := ["bash", "-cu"]
set windows-shell := ["bash", "-cu"]

image := "shard-int"

build:
	docker build -t {{image}} .

test: build
	docker run --rm {{image}}
