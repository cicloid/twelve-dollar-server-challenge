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
- `Itsi.rb` changes three settings:
  - `rackup_file "./config.ru"`: with an `Itsi.rb` present, Itsi serves only the Rack app it names,
    and its own welcome page otherwise.
  - `header_read_timeout 75.0` (default 2 s): Itsi applies it to keep-alive connections idle
    between requests, and load-test users think for longer than 2 s. With the default, 15,000 users
    made 491,693 connections in a 5-minute run, and 7.6% of requests failed with EOF.
  - `ruby_thread_request_backlog_size 100_000` (default 30 per Ruby thread): requests wait for the
    Ruby thread in a bounded queue, and Itsi answers 503 at once, without logging, when it's full.
    With the default, 0.14% of requests got a 503 at 15,000 users with p99 under 10 ms, and 2.8% at
    60,000 users on 4 vCPU.

## Results

Same `mload` setup as `ruby-cring-cicloid`, 5-minute holds, load split 60/20/20 over three load VMs.

**Our 1-vCPU test VM** (1 vCPU, 2 GB, descriptor limit 65,535), all three settings:

| | Itsi, 15,000 users | Itsi, 25,000 users | `ruby-cring-cicloid`, 60,000 users |
|---|---:|---:|---:|
| Result | pass: p95 1.0 ms, p99 14 ms | pass: p95 1.6 ms, p99 22 ms | pass: p95 3.7 ms, p99 59 ms |
| CPU per request | 151 µs | 139 µs | 72 µs |
| Peak RSS | 918 MB | 1,394 MB | 252 MB |
| Errors | 0 | 0 | 0 |

Memory is the limit: Itsi grows by about 48 MB per 1,000 users here, against about 4 MB for
`ruby-cring-cicloid`, so 2 GB runs out around 35,000 users. A run at 60,000 users before these
settings was OOM-killed at about 45,000 open connections and 1.6 GB. Itsi also uses ordinary
descriptors, so it can't hold more than 65,535 connections on this box.

**A 4-vCPU VM** (4 vCPU on 2 physical cores, 8 GB, descriptor limit 1,048,576), still one worker
and one Ruby thread, so only Itsi's Rust threads use the extra cores:

| | 15,000 users | 30,000 users | 60,000 users | 60,000 users, backlog 100,000 |
|---|---:|---:|---:|---:|
| Result | pass | pass (at the limit) | fail | **pass** |
| p95 / p99 | 0.7 / 5.3 ms | 0.7 / 8.5 ms | 0.8 / 2.9 ms | 1.9 / 20.6 ms |
| Errors (503, the backlog) | 0.58% | 1.00% | 2.82% | 0 |
| CPU per request, all threads | 150 µs | 135 µs | 132 µs | 133 µs |
| Peak RSS | 892 MB | 1,598 MB | 2,992 MB | 3,029 MB |

The first three columns ran with Itsi's default backlog. With the extra cores and memory Itsi holds
60,000 users at 5,900 requests a second, the rate `ruby-cring-cicloid` serves on one vCPU with
252 MB, at about 50 KB per connection.

Itsi's own benchmarks use a few hundred connections over loopback. This load holds tens of
thousands of mostly idle keep-alive connections, which is a different test. A run that served
Itsi's welcome page instead of the app (the `rackup_file` setting above) took 113.6 µs per request,
so most of the CPU is Itsi's own path between hyper and the Ruby thread, not the app.

Test suite: 42/42.

## License

MIT, under the repo's [license](../../LICENSE). Itsi itself is LGPL-3.0.
