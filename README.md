# Blocking IO in async code, explained

A minimal Django demo proving one thing: **an async stack (uvicorn) gives you
zero benefit - and can even hurt - if your `async def` views make blocking IO
calls.**

## The setup

Two single-file Django apps, each simulating a 100 ms IO call (think: a
database query, an HTTP call to another service):

| File | Interface | Endpoints |
|---|---|---|
| `app_async.py` | Django ASGI | `/blocking` - `time.sleep(0.1)` inside an `async def` view: freezes the event loop. `/non-blocking` - `await asyncio.sleep(0.1)`: yields to the event loop. `/blocking-sync-view` - the same `time.sleep(0.1)` in a plain `def` view: Django runs it in a thread. |
| `app_sync.py` | Django WSGI | `/blocking` - the same `time.sleep(0.1)` in a plain `def` view: normal for a sync worker. |

Both are served by gunicorn with the **same production-style config** - the
only difference is the worker class:

```bash
# ASGI: 3 uvicorn workers (one event loop each), using the prod worker
# subclass from worker.py (loop/http "auto", lifespan off for Django)
gunicorn app_async:app \
  --workers=3 \
  --worker-class worker.UvicornWorker \
  --timeout 120 \
  --bind 0.0.0.0:8001 \
  --preload \
  --access-logfile '-'

# WSGI: 3 plain sync workers
gunicorn app_sync:app \
  --workers=3 \
  --timeout 120 \
  --bind 0.0.0.0:8002 \
  --preload \
  --access-logfile '-'

# WSGI: 3 gthread workers with 20 threads each (60 request slots)
gunicorn app_sync:app \
  --workers=3 \
  --worker-class gthread \
  --threads 20 \
  --timeout 120 \
  --bind 0.0.0.0:8003 \
  --preload \
  --access-logfile '-'
```

## Running the demo

Requires [uv](https://docs.astral.sh/uv/) and [wrk](https://github.com/wg/wrk).

```bash
uv sync
./bench.sh
```

The script starts each server, hits every scenario with
`wrk -t4 -c50 -d10s` (50 concurrent connections for 10 seconds), and prints a
summary. Takes about 60 seconds.

## Results

| Scenario (3 workers each) | Throughput | p99 latency |
|---|---|---|
| ASGI, `async def` view + blocking `time.sleep` | **~20 req/s** (+ timeouts!) | ~1.8 s |
| ASGI, `async def` view + proper `asyncio.sleep` | **~300 req/s** | ~230 ms |
| ASGI, plain `def` view + blocking `time.sleep` | **~300 req/s** | ~160 ms |
| ASGI, plain `def` view, bounded to 3×5 slots (semaphore) | **~140 req/s** | ~790 ms |
| WSGI sync workers, `def` view + blocking `time.sleep` | **~30 req/s** | ~1.6 s |
| WSGI gthread workers (3×20 threads) + blocking `time.sleep` | **~450 req/s** | ~170 ms |

## What this means

**The math.** Every request "waits on IO" for 100 ms. A single event loop that
is *blocked* during that wait can serve at most 10 req/s - it executes
requests strictly one after another, exactly like a sync worker. So 3 uvicorn
workers running a blocking `async def` view have the same theoretical ceiling
as 3 sync workers: ~30 req/s. All the async machinery buys nothing.

**In practice it's even worse than sync.** The blocking-async run came in at
the same level as the sync run but produced far more request timeouts. Each
uvicorn worker eagerly accepts a batch of connections and *then* freezes on
the blocking call, so accepted requests sit queued behind a dead event loop
and their latencies stack up (p99 ~1.9 s, many past wrk's 2 s timeout). Sync
workers accept only what they can handle; excess connections wait in the
kernel's listen backlog instead of behind a frozen loop.

**Plain sync views are safe under ASGI - by design.** Django's ASGI handler
wraps every request in its own `ThreadSensitiveContext`, so each in-flight
request runs its sync view on its own thread. The identical blocking call
that killed the `async def` view does ~300 req/s in a `def` view. The cost:
one OS thread per concurrent request (unbounded), plus the sync/async
hand-off overhead - fine at this scale, but it is not free concurrency.

**The unbounded threading CAN be bounded.** `app_async.py` ships a
`MaxConcurrencyMiddleware` - an `asyncio.Semaphore` around the ASGI app -
enabled via `MAX_CONCURRENT_REQUESTS=N` (per worker). Requests above the cap
wait in the loop's cheap async queue instead of each spawning an OS thread:
gthread semantics on ASGI. The bench runs it deliberately tight (3×5 = 15
slots for 50 connections) to make the bound visible: throughput plateaus at
the theoretical 15 × 10 = ~150 req/s and latency rises (p99 ~790 ms), but
nothing errors or times out - that's queuing, i.e. graceful backpressure.
Sized realistically (e.g. 20 per worker, like a gthread pool), the cap never
binds in normal operation and only protects you during overload. The
alternative is uvicorn's `limit_concurrency` (see `worker.py`), which *sheds*
excess requests with 503 instead of queuing them - load-shedding vs.
backpressure, pick per your upstream's retry behavior.

**gthread workers do the same job with a bounded pool - and win here.** The
same blocking view on `gthread` workers (3×20 = 60 fixed slots, enough for
wrk's 50 connections) tops the table at ~450 req/s with the cleanest
latencies. A thread owns the whole request - no event loop, no sync/async
hand-off - so per-request overhead is lowest. Under overload it degrades by
queuing (bounded threads, rising wait time), whereas ASGI-with-sync-views
degrades by spawning ever more threads. The trade-off: gthread speaks plain
request/response HTTP only - no async views, no WebSockets, no SSE.

**Async pays off when the IO actually yields.** The `async def` view with
`await asyncio.sleep()` - i.e. a driver that cooperates with the event loop,
like `httpx.AsyncClient` or Django's async ORM interface - does ~300 req/s,
limited here by wrk's 50 connections and per-request overhead, not by the
architecture. Unlike the threaded options, its concurrency ceiling is not a
thread count: the same loop could hold thousands of in-flight awaits.

## Takeaway

For a Django deployment, the one fatal combination is **blocking IO inside an
`async def` view**: `requests`, `psycopg2`-backed ORM calls, or any
other blocking library freezes the event loop and makes the async stack
perform worse than plain sync workers. The rule:

- Keep views **plain `def`** unless everything inside them is genuinely
  async - Django will thread them safely under ASGI.
- Only write `async def` views that **await all their IO** (async ORM
  queries, `httpx.AsyncClient`, ...). One stray sync call poisons the loop
  for every request on that worker.
- If the codebase is (nearly) all sync views and you don't need WebSockets
  or async views, **gthread workers are the simpler, bounded, and here even
  faster choice** - the async stack only earns its keep once the IO
  actually yields.
