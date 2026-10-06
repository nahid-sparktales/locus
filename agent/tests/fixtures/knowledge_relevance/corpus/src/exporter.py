"""Export a read-only snapshot for manual inspection."""
import json


def export_snapshot(records, target):
    payload = {"version": 3, "records": records}
    target.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return len(records)


def validate_export(payload):
    if payload.get("version") != 3:
        raise ValueError("unsupported_export_version")
    return payload["records"]
