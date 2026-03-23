default: build

set shell         := ["bash", "-cu"]
set windows-shell := ["bash", "-cu"]

image := "shard"

build:
	docker build -t {{image}} .

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

dev:
	docker compose down -v && docker compose up --build -d
