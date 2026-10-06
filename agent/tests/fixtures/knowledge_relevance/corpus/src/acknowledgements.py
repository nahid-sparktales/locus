"""Delivery acknowledgement ledger; unrelated to worker ownership leases."""
import hashlib


def acknowledgement_key(channel, event_id):
    value = f"{channel}:{event_id}".encode("utf-8")
    return hashlib.sha256(value).hexdigest()


def record_delivery_ack(connection, channel, event_id, received_at):
    """Repeated delivery acknowledgements are idempotent."""
    key = acknowledgement_key(channel, event_id)
    connection.execute(
        "INSERT OR IGNORE INTO acknowledgements(key, received_at) VALUES(?, ?)",
        (key, received_at),
    )
    return key
