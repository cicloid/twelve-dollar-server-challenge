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
# GC: every minor GC re-marks each connection's fiber and recently used connection objects, so its
# pause grows with the number of connections. Pre-size the young space (per slot-size pool, from the
# measured allocation mix) so minor GCs run every ~15 s instead of every ~2 s, keep freed pages for
# reuse, and stop malloc'd response strings from triggering extra GCs.
export RUBY_GC_HEAP_0_INIT_SLOTS="${RUBY_GC_HEAP_0_INIT_SLOTS:-1500000}"
export RUBY_GC_HEAP_1_INIT_SLOTS="${RUBY_GC_HEAP_1_INIT_SLOTS:-600000}"
export RUBY_GC_HEAP_2_INIT_SLOTS="${RUBY_GC_HEAP_2_INIT_SLOTS:-200000}"
export RUBY_GC_HEAP_3_INIT_SLOTS="${RUBY_GC_HEAP_3_INIT_SLOTS:-50000}"
export RUBY_GC_HEAP_4_INIT_SLOTS="${RUBY_GC_HEAP_4_INIT_SLOTS:-20000}"
export RUBY_GC_HEAP_FREE_SLOTS_MAX_RATIO="${RUBY_GC_HEAP_FREE_SLOTS_MAX_RATIO:-0.95}"
export RUBY_GC_MALLOC_LIMIT="${RUBY_GC_MALLOC_LIMIT:-67108864}"
export RUBY_GC_MALLOC_LIMIT_MAX="${RUBY_GC_MALLOC_LIMIT_MAX:-268435456}"
export RUBY_GC_OLDMALLOC_LIMIT="${RUBY_GC_OLDMALLOC_LIMIT:-268435456}"
export RUBY_GC_OLDMALLOC_LIMIT_MAX="${RUBY_GC_OLDMALLOC_LIMIT_MAX:-1073741824}"
export RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR="${RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR:-3}"
exec bundle exec ruby server.rb
