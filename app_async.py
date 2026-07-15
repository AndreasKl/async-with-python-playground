"""Django ASGI app served by uvicorn workers.

Three endpoints simulating a 100 ms IO call (database query, HTTP request, ...):

- /blocking           async view + time.sleep()    -> blocks the event loop
- /non-blocking       async view + asyncio.sleep() -> yields to the event loop
- /blocking-sync-view SYNC view + time.sleep()     -> Django wraps each request
                      in its own ThreadSensitiveContext, so every in-flight
                      request gets its own thread: blocking is absorbed.

Run (mirrors prod config, incl. the custom worker from worker.py):
    uv run gunicorn app_async:app \
        --workers=3 \
        --worker-class worker.UvicornWorker \
        --timeout 120 \
        --bind 0.0.0.0:8001 \
        --preload \
        --access-logfile '-'
"""

import asyncio
import os
import time

from django.conf import settings
from django.http import HttpRequest, JsonResponse
from django.urls import path

IO_DURATION = 0.1  # seconds, simulated IO latency

settings.configure(
    DEBUG=False,
    SECRET_KEY="bench-only",
    ALLOWED_HOSTS=["*"],
    ROOT_URLCONF=__name__,
)


async def blocking(request: HttpRequest) -> JsonResponse:
    # Simulates blocking IO inside an async view, e.g. requests.get(),
    # psycopg2 queries, boto3 calls, or the sync Django ORM. The entire
    # event loop is frozen for the duration - no other request progresses.
    time.sleep(IO_DURATION)
    return JsonResponse({"io": "blocking"})


async def non_blocking(request: HttpRequest) -> JsonResponse:
    # Simulates proper async IO, e.g. httpx.AsyncClient, the async ORM
    # on an async-capable backend. The event loop stays free.
    await asyncio.sleep(IO_DURATION)
    return JsonResponse({"io": "non-blocking"})


def blocking_sync_view(request: HttpRequest) -> JsonResponse:
    # Same blocking call in a plain sync view. Django's ASGI handler runs
    # each request in its own ThreadSensitiveContext (one thread per
    # in-flight request), so blocking here does NOT stall other requests -
    # at the cost of one OS thread per concurrent request.
    time.sleep(IO_DURATION)
    return JsonResponse({"io": "blocking-sync-view"})


urlpatterns = [
    path("blocking", blocking),
    path("non-blocking", non_blocking),
    path("blocking-sync-view", blocking_sync_view),
]

# Imported lazily so settings.configure() above runs first.
from django.core.asgi import get_asgi_application  # noqa: E402


class MaxConcurrencyMiddleware:
    """Bound in-flight requests per worker with a semaphore.

    Requests above the cap wait in the (async, cheap) queue instead of each
    spawning an OS thread - the same bounded-pool semantics as gunicorn's
    gthread worker, but for ASGI. Alternative: uvicorn's limit_concurrency
    (see worker.py), which sheds excess requests with 503 instead of queuing.
    """

    def __init__(self, app, limit: int) -> None:
        self.app = app
        self.semaphore = asyncio.Semaphore(limit)

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        async with self.semaphore:
            await self.app(scope, receive, send)


app = get_asgi_application()

# 0 = unbounded (Django's default behavior). The bench sets this to show the
# bound in action; in prod pick a cap sized like a gthread pool would be.
MAX_CONCURRENT_REQUESTS = int(os.getenv("MAX_CONCURRENT_REQUESTS", "0"))
if MAX_CONCURRENT_REQUESTS:
    app = MaxConcurrencyMiddleware(app, MAX_CONCURRENT_REQUESTS)
