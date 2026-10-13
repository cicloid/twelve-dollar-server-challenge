#!/usr/bin/env bash
# Runs the server in the foreground. Config: SQLITE_PATH, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
ulimit -Sn "$(ulimit -Hn)" 2>/dev/null || true
export PATH="/opt/ruby/bin:$PATH"
export RUBY_YJIT_ENABLE=1
# io-stream reads in 256 KiB blocks by default, sized per connection; requests here are under 1 KiB
# and larger ones still read fine in several steps. Keeps idle keep-alive connections small.
export IO_STREAM_BLOCK_SIZE="${IO_STREAM_BLOCK_SIZE:-4096}"
exec bundle exec ruby server.rb
