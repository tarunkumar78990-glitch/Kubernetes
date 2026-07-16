"""Structured JSON logging that Cloud Logging parses natively."""
import logging
import os
import sys

from pythonjsonlogger import jsonlogger


class CloudLoggingFormatter(jsonlogger.JsonFormatter):
    """Cloud Logging wants 'severity', not 'levelname'."""

    def add_fields(self, log_record, record, message_dict):
        super().add_fields(log_record, record, message_dict)
        log_record["severity"] = record.levelname
        log_record["service"] = os.getenv("SERVICE_NAME", "unknown")
        log_record["env"] = os.getenv("APP_ENV", "unknown")
        log_record["version"] = os.getenv("APP_VERSION", "unknown")
        log_record.pop("levelname", None)


def get_logger(name: str = __name__) -> logging.Logger:
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        CloudLoggingFormatter("%(asctime)s %(levelname)s %(name)s %(message)s")
    )
    logger.addHandler(handler)
    logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    logger.propagate = False
    return logger


log = get_logger("app")
