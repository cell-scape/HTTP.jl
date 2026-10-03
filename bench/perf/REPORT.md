# HTTP.jl Performance Investigation

**Date:** 2026-02 · **Machine:** Intel i9-10980XE (36 logical cores), Linux, loopback, no TLS
**Julia:** 1.13.1 · **HTTP.jl:** this checkout (2.x dev) · **Reseau:** 1.5.0
**Comparator:** hyper 1.x + tokio (16 workers), built locally with `opt-level=3, lto, codegen-units=1`
**Load generator:** `raw_load.jl` (raw TCP, keep-alive, preallocated buffers, minimal allocs —
see "Scripts" below). Same generator drives HTTP.jl and hyper, so cross-library numbers are
apples-to-apples on this box (the generator itself tops out around ~600k rps).

---

## Headline results

| Configuration | c=1 p50 | c=64 | c=256/320 | tail p99 @c=256 |
|---|---:|---:|---:|---:|
| hyper 1.x, 16 workers (`/json`) | 16.4 µs | 426,620 rps | **621,728 rps** | 0.9 ms |
| HTTP.jl stock, `-t 16` (`:interactive` pool) | 27.2 µs | 57,299 rps | 54,247 rps | 6.0 ms |
| HTTP.jl **one-line fix** (default pool), `-t 16` | 24.7 µs | 284,869 rps | 339,799 rps | 12.0 ms |
| … with more threads (`-t 16` srv, `-t 18` gen) | — | 446,368 (c=128) | **483,591 (c=320)** | 4.2 ms |

Throughput of stock HTTP.jl is **~9% of hyper**; with a one-line scheduling change it reaches
**~78% of hyper** (measured with a Julia-client load generator that nears its own ceiling
around 600k rps, so hyper's true headroom is plausibly higher).

Single-connection round-trip: HTTP.jl 24.7 µs vs hyper 16.4 µs (~1.5×) — this is the pure
parse/serialize/alloc floor of the stack and is where the remaining per-request work lives.

---

## Finding 1 (dominant): the server runs on ONE thread by default

`@_spawn_interactive` (= `Threads.@spawn :interactive`) is used for listener, connection,
HTTP/2 stream, SSE, and WebSocket tasks (PR #1344, deliberate: isolate HTTP work from the
`:default` pool so health checks stay responsive). But plain `julia --threads=N` (the common
case) creates **N default threads + exactly 1 interactive thread**, so every connection is
serialized onto a single core:

- Verified directly: 6,405/6,405 requests handled on `threadid() == 1` under 32-way load.
- Behavioral signature: throughput caps ~54–66k rps while p50 grows linearly with
  concurrency (27 µs → 56 µs → 227 µs → 1.0 ms → 4.6 ms for c = 1→4→16→64→256) — a pure
  single-server queueing curve, exactly what one busy core produces.
- One-line change (`Threads.@spawn` on the connection task) → **5–6× throughput and 13×
  p50 latency** improvement at c=64, ~9× ceiling at c=320.
- `-t 4,8` (8 interactive threads, unmodified source) scales to ~333k rps — the design can
  scale but requires nonstandard flags nobody uses for servers today.

**Recommendation options** (biggest single win available, needs a design decision):
1. Add a `spawn`/`pool` keyword to `serve!`/`listen!` (default `:default` or `:interactive`
   documented loudly), or
2. keep `:interactive` but document `-t N,M` with M>1 for production and warn at startup
   when `Threads.nthreads(:interactive) == 1`, or
3. hybrid: a couple of connections on interactive, overflow to default.

Applies equally to `http2_server.jl:1622`, `http_handlers.jl:561`, `http_sse.jl:242`,
`http_websockets.jl` (two sites).

---

## Finding 2: parse path allocates ~114 objects / 5.4 KB per request

**Status: FIXED (2026-02) — see "Parse-path fixes" section below.** Kept for
history:

`read_request` on a typical 9-header GET (micro-bench, `micro_parse_serialize.jl`):

- 7.96 µs, 5,472 B allocated (IOBuffer path); ~4 µs via the `_ConnReader` fast path.
- Allocation profile (`alloc_profile.jl`): `_read_headers` alone = 90 allocs / 3,119 B.

Per header line today: 1 line `String` (fast-path `unsafe_string`) + 1 key `String` +
`canonical_header_key` (sometimes +1 more, and the key String is wasted on cache hits) +
value normalized via **two** copies (`String(value)` + `String(SubString(...))` in
`_trim_http_ows`, which always allocates even when there is nothing to trim).

Concrete low-risk fixes, in impact order:

| Fix | Est. savings |
|---|---|
| `_normalize_header_field_value`: detect the common "no rewrite, no trim" case and materialize one `String` from the byte range (or return the line `String` itself) | −2 allocs/header → ~−20/req |
| `canonical_header_key`: run the canonical-check on the `SubString` *before* `String(key)`; only materialize on cache miss | −1 alloc/header for common names |
| `_parse_http_version`: fixed-shape byte parse of `HTTP/d.d` instead of `split` + `parse` + try/catch | −4 allocs/req, faster |
| `headers(hdrs, key)` builds a `Vector{String}` per lookup; the parse path calls it 3× (Content-Length, TE, Host). Add internal non-allocating first-value/contains helpers | −3 allocs/req |
| `_readline_crlf` generic (non-ConnReader) path is byte-at-a-time `push!` — used by proxy/websocket handoff paths; give `IOBuffer` the same scan-then-`unsafe_string` fast path | latency only |

Target after fixes 1–4: ~30 allocs / ~2.5 KB per request — roughly half the GC load at
high request rates.

## Finding 3: response path costs

- `write_response!` 150 B JSON: 1.21 µs / 960 B. 204: 0.75 µs / 512 B.
- Per response: `copy(response.headers)`, `mkheaders` on construction, fresh `IOBuffer`
  per head (already correctly single-`write` to the socket — that fix from the earlier
  optimization round is working), `take!(io)` moves the byte array.
- Cheap wins: reuse a per-connection response-head buffer (arena-style `IOBuffer` with
  `truncate` instead of `take!`), and skip the header `copy()` when the response is
  freshly built by a handler (mark headers "owned/not shared" with a flag instead).

## Finding 4: GC is the latency-tail story

At ~460k rps the server allocates ~2.9 GB/s. Server `gc_time` ≈ 7–8% of wall under load,
and the p99 tail shows it: 4–12 ms vs hyper's 0.9 ms (hyper: zero-alloc steady state).
Findings 2+3 attack this directly; further headroom would need pooled/arena request
objects (the earlier REPORT.md's "zero-alloc request hot path" item, est. 1.5–2× at c=1).

## Finding 5: where CPU goes under load (profile @ 467k rps, `-t 12`)

| Area | Share |
|---|---:|
| Reseau transport (epoll, timers, syscalls, locks) | 29.7% |
| Base (alloc, GC, locks, parse, print machinery) | 28.2% |
| HTTP.jl code | 42.2% |

Top HTTP.jl frames: `_serve_h1_conn!` 6.6%, `write_response!` 3.4%, `read_request` 1.4%,
`_fill_conn_reader!` 1.4%, body write 0.9%, `Response`/`Headers` construction ~0.9%.
Within Reseau, timer-heap operations under a global lock (`_time_peek_locked`,
`slowlock`) are visible — per-thread timer wheels or lazier deadline computation would
trim syscalls/locks (relevant because every request arms/clears deadline state even when
no timeouts are configured — the earlier "skip deadline kernel calls" fix removed most,
but timer-heap churn remains).

## Finding 6: HTTP/2 (secondary)

The H/2 stream handler spawns per stream on the same single interactive thread, so Finding
1 applies there too. Still open from the earlier round: HPACK encode caching for repeat
responses (est. 5–10%), per-response buffer pooling (est. 5%).

---

## What HTTP.jl already does right (keep)

- `_ConnReader` fast-path line reads: direct `unsafe_string` from the connection buffer,
  no per-byte copies (http_transport.jl:1455).
- Single syscall per response head (IOBuffer batch) — the previous round's biggest fix.
- Zero-copy `BytesBody` body writes (no memcpy of response bodies).
- Strict-CRLF parsing in a smuggling-safe way (correctness first — good trade).

## Hyper-vs-HTTP.jl design deltas worth stealing

1. hyper parses into borrowed `&[u8]` slices with zero intermediate `String`s; HTTP.jl's
   public `Headers` API (`Vector{Pair{String,String}}`-like) forces materialization — but
   the fixes in Finding 2 halve the cost without touching the API.
2. hyper's per-connection task model has no global scheduler bottleneck; Julia's `:interactive`
   pool recreated one (Finding 1).
3. hyper never allocates in steady state; HTTP.jl's realistic floor with Finding 2+3 fixes
   is ~2–3 KB/request — GC stays in the tail until arenas/pools land (Finding 4).

---

## Scripts (all in this directory)

```sh
# micro-benchmarks (parse/serialize/component costs + allocs)
julia --project=../.. -t 4 micro_parse_serialize.jl
# allocation profile of read_request
julia --project=../.. -t 2 alloc_profile.jl
# end-to-end: server + raw-socket load generator
julia --project=../.. -t 16 perf/e2e_server.jl 19300 60 &   # prints READY
julia --project=../.. -t 18 perf/raw_load.jl 19300 128 6000 /json
# reproduce Finding 1: change `@_spawn_interactive _serve_conn!` → `Threads.@spawn`
# in src/http_server.jl:1303 and rerun the two commands above.
```

Raw numbers behind every table above are in the transcript of this investigation session;
scripts print them live.

---

# Parse-path fixes (2026-02, applied to this tree)

Changes (all semantics-preserving; full test suite green except a pre-existing
`JuliaC`-missing trim-compile failure that also fails on the clean tree):

1. **`_read_headers`** — key/value stay `SubString`s of the line; the
   whitespace-before-`:` check reads edge bytes instead of comparing against an
   allocated trimmed copy; the value goes straight to the normalizer.
2. **`_normalize_header_field_value`** — scans borrowed bytes; materializes at
   most ONE String per value (the old path always did `String(value)` +
   `String(SubString(...))`); returns the input object when already normalized
   (also cuts the *outgoing* header path to zero-alloc per clean header).
3. **`canonical_header_key`** — cache lookup on the borrowed key before any
   copy (common names: 0 allocs); non-canonical rewrite goes through a byte
   buffer instead of `Vector{Char}` (4 B/char → 1 B/char).
4. **`_parse_http_version`** — fixed-shape `HTTP/d.d` byte fast path; the
   split/parse/try-catch path remains as fallback with identical errors.
5. **`_parse_int64_decimal_header_value`** — trims by byte bounds, parses in
   place (no per-value String copy).
6. **`_parse_content_length` / `_parse_transfer_encoding!` /
   `_validate_request_host!`** — allocation-free scans
   (`_first_header_value` / `_count_header_values`) instead of `headers()`
   which materialized a `Vector{String}` per call (3× per request).

## Results

Micro (`micro_parse_serialize.jl`, this machine, Julia 1.13):

| metric | before | after | Δ |
|---|---:|---:|---:|
| `read_request` typical GET (9 hdrs) | 7.96 µs / 5,472 B | 6.99 µs / 4,272 B | −12% / −22% |
| `read_request` small GET (3 hdrs) | 2.63 µs / 2,240 B | 2.13 µs / 1,616 B | −19% / −28% |
| **server path** (`_ConnReader` fast path) | **2,928 B / 67 allocs** | **1,728 B / 35 allocs** | **−41% / −48%** |
| `canonical_header_key` lowercase | 0.14 µs / 256 B | 0.06 µs / 80 B | −57% / −69% |
| `write_response!` 150 B json (bonus) | 1.21 µs / 960 B | 1.15 µs / 848 B | −5% / −12% |

E2E (raw-socket loadgen, `/json`, stock `:interactive` spawn, `-t 8` server,
back-to-back A/B in one load window — median of 3 runs):

| | before | after | Δ |
|---|---:|---:|---:|
| rps @ c=64 | 53,058 | 57,511 | **+8.4%** |
| p50 | 1,129 µs | 1,013 µs | −10% |
| p99 | 1,896 µs | 1,576 µs | −17% |

(On the single interactive thread the parse saving is ~1.2 µs of ~17 µs per
request; the GC-tail improvement shows in p99. Under the default-pool
configuration from Finding 1 the same per-request saving is worth more as
throughput, but that combination was not A/B-measured on an idle box.)

Remaining parse-path allocs (35/req): ~20 are Strings (1 per line + method +
target — the floor for the `Headers::Vector{Pair{String,String}}` API), ~10
are `RequestContext` internals (lock, callback list) and `Headers`/trailers
containers. Next structural steps would be per-connection header arenas or a
resettable RequestContext (see Finding 4).
