# Archived lease API, version 2

This document describes the retired protocol. It is retained for migration work
and must not be used to configure a current client.

## Defaults

The old default lease duration was 30 seconds. The service sometimes renewed a
lease on any request from its owner, even an unrelated notebook search.

## Conflicts

Version 2 accepted a sequence number named etag. A mismatched sequence returned
HTTP 412. Version 3 replaced this field with expected_revision and HTTP 409.
