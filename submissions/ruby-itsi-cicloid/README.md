# Ruby + Itsi + SQLite B-tree reads

Just for the lols: the app from [`ruby-btreereads-cicloid`](../ruby-btreereads-cicloid) as a plain Rack
app on [Itsi](https://itsi.fyi/), a Ruby app server with its HTTP and I/O in Rust (tokio and hyper).
I wanted to see what an off-the-shelf fast server does with our Ruby, against the connection layer
we wrote ourselves in [`ruby-cring-cicloid`](../ruby-cring-cicloid).

| | |
|---|---|
| Language | Ruby 4.0.7 with YJIT, built from source with jemalloc and `-march=native` |
| Framework | [Itsi](https://itsi.fyi/) (`itsi-server` 0.2.27, compiled from its source gem with Ubuntu's cargo 1.91), one process, one Ruby thread |
| SQLite driver | `ext/lite.c`, as in `ruby-btreereads-cicloid`: the SQLite 3.54.0 amalgamation compiled in, profile-guided |
| Reads | `GET /feed` and `GET /posts/:id` rendered in `ext/lite.c` from SQLite's B-tree cursors |
| Writes | SQL, each write its own `BEGIN IMMEDIATE ... COMMIT` |
| JWT | HMAC-SHA256 from libsodium 1.0.22 through rbnacl 7.1.2 |
| JSON | read documents from `ext/lite.c`, write documents from SQLite; json 2.21.2 (Itsi needs json 2.x) |
| **Nginx or direct** | **Direct** |

## Running it

```bash
sudo bash install.sh   # Ruby, libsodium, SQLite amalgamation, plus cargo-1.91/rustc-1.91 and libclang-dev
bash build.sh          # gems (Itsi's Rust extension takes ~15 min on 1 vCPU), then ext/lite.so
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## What changed from `ruby-btreereads-cicloid`

- `config.ru` replaces the server: Itsi parses HTTP, and the app gets the method, path,
  `Authorization` header and body from the Rack env.
- With one Ruby thread running one request at a time, there's no reactor pass to group writes in,
  so each write commits on its own (WAL with `synchronous=NORMAL`, so no fsync).
- Checkpoints and the full-GC check run between requests on the request thread, once a second.
- `Itsi.rb` names `config.ru` (with an `Itsi.rb` present, Itsi serves only the `rackup_file` it
  names, and its own welcome page otherwise) and raises `header_read_timeout` from 2 s to 75 s. Itsi applies it to keep-alive connections
  idle between requests, and load-test users think for longer than 2 s. With the default, 15,000
  users made 491,693 connections in a 5-minute run, and 7.6% of requests failed with EOF.

## Results on our 1-vCPU test VM

Same VM and `mload` setup as `ruby-cring-cicloid` (1 vCPU, 2 GB, descriptor limit 65,535), 5-minute
holds, load split 60/20/20 over three load VMs:

| | Itsi, 15,000 users | `ruby-cring-cicloid`, 60,000 users |
|---|---:|---:|
| Result | pass: p95 0.8 ms, p99 8.3 ms | pass: p95 3.7 ms, p99 59 ms |
| CPU per request | 133.5 µs | 72.3 µs |
| Peak RSS | 891 MB | 252 MB |
| Errors | 0.144% (767 × 503 from Itsi, nothing logged) | 0 |

At 60,000 users, p95 passed 0.9 s at about 35,000 users in total (the ramp seen from the load VM
with 60% of them), and at about 45,000 open connections the server reached 1.6 GB and the kernel's
OOM killer stopped it. Requests the one Ruby thread hasn't reached yet wait in Rust; at 15,000
users the process already used 891 MB, about 59 KB per connection against about 4 KB in
`ruby-cring-cicloid`. Itsi also uses ordinary descriptors, so it can't hold more than 65,535
connections on this box.

Itsi's own benchmarks use a few hundred connections over loopback. This load holds tens of
thousands of mostly idle keep-alive connections, which is a different test.

A run of Itsi's welcome page at 15,000 users (the `rackup_file` mistake above) took 113.6 µs per
request, so most of the 133.5 µs is Itsi's own path between hyper and the Ruby thread, not the app.

Test suite: 42/42.

## License

MIT, under the repo's [license](../../LICENSE). Itsi itself is LGPL-3.0.
