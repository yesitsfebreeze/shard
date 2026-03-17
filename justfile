default: build

set shell         := ["bash", "-cu"]
set windows-shell := ["powershell", "-NoLogo", "-NoProfile", "-Command"]
set quiet         := true

pkg  := "./src"
ext  := if os() == "windows" { ".exe" } else { "" }
bin  := "./bin/shard" + ext
args := "-o:speed -vet -strict-style"

[unix]
test: _mkdir_bin
	#!/usr/bin/env bash
	set -euo pipefail
	find src -type d -name 'tests' | while read dir; do
		echo ""
		echo "▶ testing $dir..."
		extra=""
		[[ "$dir" == *fs/tests* ]] && extra="-define:ODIN_TEST_THREADS=1"
		odin test "./$dir" -define:ODIN_TEST_LOG_LEVEL=warning $extra || exit 1
	done

[windows]
test: _mkdir_bin
	#!powershell
	$dirs = Get-ChildItem -Path "src" -Recurse -Directory -Filter "tests"
	foreach ($d in $dirs) {
		$rel = $d.FullName.Substring((Get-Location).Path.Length + 1) -replace "\\", "/"
		Write-Host ""
		Write-Host "▶ testing $rel..."
		$extra = ""
		if ($rel -like "*fs/tests*") { $extra = "-define:ODIN_TEST_THREADS=1" }
		$cmd = "odin test `"./$rel`" -define:ODIN_TEST_LOG_LEVEL=warning -define:ODIN_TEST_SHORT_LOGS=true $extra"
		Invoke-Expression $cmd
		if ($LASTEXITCODE -ne 0) { exit 1 }
	}

[unix]
_mkdir_bin:
  @mkdir -p bin

[windows]
_mkdir_bin:
  @if (-not (Test-Path "bin")) { New-Item -ItemType Directory -Path "bin" | Out-Null }

build: test _mkdir_bin
  odin build {{pkg}} -out:{{bin}} {{args}} -debug

run: _mkdir_bin 
  @echo "!! this just runs the app"
  @echo "!! it expects no errors and working tests"
  odin run {{pkg}} -out:{{bin}} {{args}} -debug

release: test _mkdir_bin
  odin build {{pkg}} -out:{{bin}} {{args}}
  just compress

[unix]
clean:
  @rm -rf bin

[windows]
clean:
  #!powershell
  if (Test-Path "bin") { Remove-Item -Recurse -Force "bin" }

[unix]
compress:
  $size=$(stat -c%s {{bin}}); printf "size: %.2f MB\n" $(echo "$size / 1024 / 1024" | bc -l)
  echo "compressing with upx..."
  upx --best --lzma -f -o {{bin}}_tmp {{bin}}
  rm -f {{bin}}
  mv {{bin}}_tmp {{bin}}
  $compSize=$(stat -c%s {{bin}}); printf "compressed size: %.2f MB\n" $(echo "$compSize / 1024 / 1024" | bc -l)


[windows]
compress:
  $size = (Get-Item {{bin}}).Length; Write-Host "size: $([math]::Round($size / 1MB, 2)) MB"
  Write-Host "compressing with upx..."
  upx --best --lzma -f -o {{bin}}_tmp {{bin}}
  Remove-Item -Force {{bin}}
  Move-Item -Force {{bin}}_tmp {{bin}}
  $compSize = (Get-Item {{bin}}).Length; Write-Host "compressed size: $([math]::Round($compSize / 1MB, 2)) MB"