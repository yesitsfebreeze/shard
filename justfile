default: build

set shell         := ["bash", "-cu"]
set windows-shell := ["powershell", "-NoLogo", "-NoProfile", "-Command"]
set quiet         := true

pkg      := "./src"
ext      := if os() == "windows" { ".exe" } else { "" }
bin      := "./bin/shard" + ext
test_bin := "./bin/test-shard" + ext
args     := "-o:speed -vet -strict-style"

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

test-build: test _mkdir_bin
  odin build {{pkg}} -out:{{test_bin}} {{args}} -debug

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
  #!/usr/bin/env bash
  set -euo pipefail
  
  if [[ "$(uname)" == "Darwin" ]]; then
    size=$(stat -f "%z" {{bin}})
  else
    size=$(stat -c%s {{bin}})
  fi
  
  printf "size: %.2f MB\n" $(echo "$size / 1024 / 1024" | bc -l)
  echo "compressing with upx..."
  if [[ "$(uname)" == "Darwin" ]]; then
    upx --force-macos --best --lzma -f -o {{bin}}_tmp {{bin}}
  else
    upx --best --lzma -f -o {{bin}}_tmp {{bin}}
  fi
  rm -f {{bin}}
  mv {{bin}}_tmp {{bin}}
  if [[ "$(uname)" == "Darwin" ]]; then
    compSize=$(stat -f "%z" {{bin}})
  else
    compSize=$(stat -c%s {{bin}})
  fi
  
  printf "compressed size: %.2f MB\n" $(echo "$compSize / 1024 / 1024" | bc -l)


[windows]
compress:
  $size = (Get-Item {{bin}}).Length; Write-Host "size: $([math]::Round($size / 1MB, 2)) MB"
  Write-Host "compressing with upx..."
  upx --best --lzma -f -o {{bin}}_tmp {{bin}}
  Remove-Item -Force {{bin}}
  Move-Item -Force {{bin}}_tmp {{bin}}
  $compSize = (Get-Item {{bin}}).Length; Write-Host "compressed size: $([math]::Round($compSize / 1MB, 2)) MB"

# Trigger GitHub CI and report build errors
[unix]
ci-check:
  #!/usr/bin/env bash
  set -euo pipefail
  
  # Install gh if not found
  if ! command -v gh &> /dev/null; then
    echo "Installing gh CLI..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      brew install gh
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo apt update
      sudo apt install gh
    fi
  fi
  
  echo "Triggering GitHub Actions workflow..."
  if ! gh workflow run build.yml -f tag=ci-check 2>&1; then
    echo ""
    echo "Error: Failed to trigger workflow. Make sure you're authenticated:"
    echo "  gh auth login"
    echo "or set GH_TOKEN environment variable"
    exit 1
  fi
  
  echo "Waiting for workflow to complete..."
  echo "This may take a few minutes..."
  
  # Poll for workflow completion
  while true; do
    run_info=$(gh run list --workflow build.yml --limit 1 --json status,conclusion 2>/dev/null || echo '[{"status":"in_progress","conclusion":null}]')
    status=$(echo "$run_info" | jq -r '.[0].status')
    conclusion=$(echo "$run_info" | jq -r '.[0].conclusion')
    
    if [ "$status" == "completed" ]; then
      break
    fi
    
    echo "  status: $status..."
    sleep 30
  done
  
  echo ""
  echo "=== Build Results ==="
  
  if [ "$conclusion" == "success" ]; then
    echo "All platforms built successfully!"
    gh run view --json jobs --jq '.jobs[] | "\(.name): \(.status)"'
  else
    echo "Build failed!"
    echo ""
    echo "=== Failed Jobs ==="
    gh run view --json jobs --jq '.jobs[] | select(.conclusion == "failure") | "\(.name) failed"' || true
    
    echo ""
    echo "=== Error Logs ==="
    gh run view --json jobs --jq '.jobs[] | select(.conclusion == "failure") | .name' | while read job; do
      echo "--- $job ---"
      gh run view --log "$job" 2>/dev/null | tail -50 || echo "(no logs available)"
    done
    
    exit 1
  fi