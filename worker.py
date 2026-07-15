"""Custom uvicorn worker, mirroring the production configuration."""

from uvicorn_worker import UvicornWorker as BaseUvicornWorker


class UvicornWorker(BaseUvicornWorker):
    """
    Certain settings of Uvicorn are not available when run through Gunicorn as webserver.
    Those settings can be configured by subclassing the Uvicorn worker and overwriting the CONFIG_KWARGS.

    For more info see: https://www.uvicorn.org/deployment/#gunicorn
    """

    CONFIG_KWARGS = {
        "loop": "auto",  # default
        "http": "auto",  # default
        "lifespan": "off",  # toggled off since Django does not support it
        # "limit_concurrency": 60,  # bound in-flight requests per worker;
        # excess requests are SHED with 503. For queuing semantics instead,
        # see MaxConcurrencyMiddleware in app_async.py.
    }
