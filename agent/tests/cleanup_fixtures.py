"""Scripted selected-model cleanup responses for deterministic lifecycle tests."""
import json


def cleanup_reply(summary: str) -> str:
    return json.dumps({
        "summary": summary,
        "checkpoint": {"objective": "Continue the requested work", "unfinished_work": [],
                       "decisions": [], "blockers": [], "next_steps": [], "evidence_refs": []},
        "candidates": [], "resolved_inputs": [],
    })
