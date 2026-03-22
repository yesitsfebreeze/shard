default: build

set shell         := ["bash", "-cu"]
set windows-shell := ["powershell", "-NoLogo", "-NoProfile", "-Command"]

image := "shard-v3"

[unix]
build:
	docker build -t {{image}} . && docker run --rm {{image}}

[windows]
build:
	docker build -t {{image}} . ; docker run --rm {{image}}

[unix]
run:
	docker run --rm -it {{image}} bash

[windows]
run:
	docker run --rm -it {{image}} bash

clean:
	docker rmi {{image}} -f
