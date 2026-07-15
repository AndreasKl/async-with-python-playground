#!/usr/bin/env bash
# Demo: blocking IO in an async Django stack (uvicorn workers) removes all
# benefit of async.
#
# Both servers run the SAME Django app style with the SAME prod-style gunicorn
# config (3 workers, --preload, --timeout 120); the only difference is the
# worker class. Four scenarios, each hammered with wrk (50 connections, 10s):
#
#   1. UvicornWorker, async view, time.sleep(0.1)    -> ~20 req/s
#   2. UvicornWorker, async view, asyncio.sleep(0.1) -> ~200 req/s
#   3. UvicornWorker, SYNC view,  time.sleep(0.1)    -> ~400 req/s
#      (Django runs each request in its own ThreadSensitiveContext:
#       one thread per in-flight request absorbs the blocking call)
#   4. UvicornWorker, SYNC view, bounded to 3x5 slots -> ~150 req/s
#      (MaxConcurrencyMiddleware semaphore: requests above the cap queue
#       on the loop instead of spawning threads - gthread semantics on ASGI)
#   5. sync worker,   sync view,  time.sleep(0.1)    -> ~30 req/s
#   6. gthread worker (3x20 threads), sync view      -> ~450 req/s
#      (fixed thread pool: 60 slots, bounded and predictable)
#
# Conclusion: blocking IO inside an ASYNC view (1) freezes the event loop and
# performs no better than plain sync workers (4). A plain sync view (3) is
# safe under ASGI because Django gives it a thread per request - and gthread
# workers (5) achieve the same with a BOUNDED pool. Only truly non-blocking
# IO (2) or threaded sync views (3, 5) deliver concurrency.

set -euo pipefail
cd "$(dirname "$0")"

DURATION=10s
CONNECTIONS=50
WRK_THREADS=4

ASGI_PORT=8001
WSGI_PORT=8002
GTHREAD_PORT=8003
GTHREAD_THREADS=20
ASGI_BOUND=5  # deliberately tight (3x5=15 slots < 50 conns) to show queuing

declare -a NAMES RESULTS

wait_ready() {
    for _ in $(seq 100); do
        curl -sf "$1" > /dev/null && return 0
        sleep 0.1
    done
    echo "server at $1 did not come up" >&2
    exit 1
}

bench() {
    local name=$1 url=$2
    echo
    echo "=== $name ==="
    echo "    wrk -t$WRK_THREADS -c$CONNECTIONS -d$DURATION $url"
    local out
    out=$(wrk -t"$WRK_THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency "$url")
    echo "$out"
    NAMES+=("$name")
    RESULTS+=("$(echo "$out" | awk '/Requests\/sec/ {print $2}')")
}

cleanup() {
    kill $(jobs -p) 2> /dev/null || true
}
trap cleanup EXIT

echo ">>> Starting gunicorn with Uvicorn workers (port $ASGI_PORT)"
echo "    3 workers, each a single event loop - access log in asgi.log"
uv run gunicorn app_async:app \
    --workers=3 \
    --worker-class worker.UvicornWorker \
    --timeout 120 \
    --bind "127.0.0.1:$ASGI_PORT" \
    --preload \
    --access-logfile '-' > asgi.log 2>&1 &
ASGI_PID=$!
wait_ready "http://127.0.0.1:$ASGI_PORT/non-blocking"

bench "ASGI + async view + BLOCKING IO (time.sleep)" \
    "http://127.0.0.1:$ASGI_PORT/blocking"
bench "ASGI + async view + proper async IO (asyncio.sleep)" \
    "http://127.0.0.1:$ASGI_PORT/non-blocking"
bench "ASGI + SYNC view + BLOCKING IO (thread per request)" \
    "http://127.0.0.1:$ASGI_PORT/blocking-sync-view"

kill $ASGI_PID
wait $ASGI_PID 2> /dev/null || true

echo
echo ">>> Restarting ASGI server with MAX_CONCURRENT_REQUESTS=$ASGI_BOUND"
echo "    semaphore middleware bounds in-flight requests (and thus threads)"
MAX_CONCURRENT_REQUESTS=$ASGI_BOUND uv run gunicorn app_async:app \
    --workers=3 \
    --worker-class worker.UvicornWorker \
    --timeout 120 \
    --bind "127.0.0.1:$ASGI_PORT" \
    --preload \
    --access-logfile '-' > asgi-bounded.log 2>&1 &
ASGI_BOUNDED_PID=$!
wait_ready "http://127.0.0.1:$ASGI_PORT/non-blocking"

bench "ASGI + SYNC view + BLOCKING IO (bounded, 3x$ASGI_BOUND slots)" \
    "http://127.0.0.1:$ASGI_PORT/blocking-sync-view"

kill $ASGI_BOUNDED_PID
wait $ASGI_BOUNDED_PID 2> /dev/null || true

echo
echo ">>> Starting gunicorn with sync workers (port $WSGI_PORT)"
echo "    3 workers, plain WSGI - access log in wsgi.log"
uv run gunicorn app_sync:app \
    --workers=3 \
    --timeout 120 \
    --bind "127.0.0.1:$WSGI_PORT" \
    --preload \
    --access-logfile '-' > wsgi.log 2>&1 &
WSGI_PID=$!
wait_ready "http://127.0.0.1:$WSGI_PORT/blocking"

bench "WSGI + sync view + BLOCKING IO (3 sync workers)" \
    "http://127.0.0.1:$WSGI_PORT/blocking"

kill $WSGI_PID
wait $WSGI_PID 2> /dev/null || true

echo
echo ">>> Starting gunicorn with gthread workers (port $GTHREAD_PORT)"
echo "    3 workers x $GTHREAD_THREADS threads - access log in gthread.log"
uv run gunicorn app_sync:app \
    --workers=3 \
    --worker-class gthread \
    --threads "$GTHREAD_THREADS" \
    --timeout 120 \
    --bind "127.0.0.1:$GTHREAD_PORT" \
    --preload \
    --access-logfile '-' > gthread.log 2>&1 &
GTHREAD_PID=$!
wait_ready "http://127.0.0.1:$GTHREAD_PORT/blocking"

bench "WSGI + sync view + BLOCKING IO (gthread 3x$GTHREAD_THREADS threads)" \
    "http://127.0.0.1:$GTHREAD_PORT/blocking"

kill $GTHREAD_PID
wait $GTHREAD_PID 2> /dev/null || true

echo
echo "==================== SUMMARY ===================="
for i in "${!NAMES[@]}"; do
    printf "%-58s %10s req/s\n" "${NAMES[$i]}" "${RESULTS[$i]}"
done
echo "================================================="
echo "Every request 'waits on IO' for 100 ms. A blocking call inside an"
echo "ASYNC view freezes the whole event loop: 3 uvicorn workers degrade"
echo "to serial execution, no better than 3 plain sync workers. The same"
echo "blocking call in a plain SYNC view is fine - Django gives each"
echo "request its own (unbounded) thread under ASGI, and gthread workers"
echo "match that with a fixed, predictable pool. Either await real async"
echo "IO or keep views sync; blocking inside 'async def' is the one fatal"
echo "combination."
