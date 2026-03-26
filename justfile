default: build

set shell         := ["bash", "-cu"]
set windows-shell := ["bash", "-cu"]

build:
	#!/usr/bin/env bash
	set -euo pipefail
	OS="$(uname -s)"
	ARCH="$(uname -m)"
	case "$OS" in
		Linux)  just build-linux ;;
		Darwin)
			case "$ARCH" in
				arm64|aarch64) just build-mac ;;
				x86_64)        just build-mac-x86 ;;
				*)             echo "unsupported arch: $ARCH" && exit 1 ;;
			esac ;;
		MINGW*|MSYS*|CYGWIN*) just build-windows ;;
		*)  echo "unsupported OS: $OS" && exit 1 ;;
	esac

build-linux:
	odin build src -out:.shards/bin/shard -o:speed -vet -strict-style

build-mac:
	odin build src -out:shard -target:darwin_arm64 -o:speed -vet -strict-style

build-mac-x86:
	odin build src -out:shard -target:darwin_amd64 -o:speed -vet -strict-style

build-windows:
	odin build src -out:shard.exe -target:windows_amd64 -o:speed -vet -strict-style
