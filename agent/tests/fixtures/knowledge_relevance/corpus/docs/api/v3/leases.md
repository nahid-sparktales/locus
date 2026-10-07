# Current lease API, version 3

Version 3 is the supported protocol for new clients. Worker ownership is a lease,
not a delivery acknowledgement and not a lock on a notebook file.

## Defaults

An unconfigured lease expires after 90 seconds. Renewal extends it from the
current host clock. The owner must renew before expiry to retain ownership.

## Conflicts

Requests include expected_revision. A stale revision returns HTTP 409, with no
mutation. The client reloads the latest lease and asks the caller to retry.

## Availability

When the host cannot serve requests, HTTP 503 indicates temporary unavailability.
The client preserves the draft locally until the host returns.
