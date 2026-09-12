#!/usr/bin/env python3
"""Generate the shipped outpost assets with Meshy, with a durable credit ceiling.

Requires no dependencies. The API key is read without echo and is never saved.
Private task responses (including expiring download URLs) stay outside the repo.
Interrupted POSTs are never automatically retried: their credits stay reserved.
"""
from __future__ import annotations

import argparse
import fcntl
import getpass
import hashlib
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.meshy.ai"
TEXT = "/openapi/v2/text-to-3d"
RIG = "/openapi/v1/rigging"
ANIMATE = "/openapi/v1/animations"
STYLE = "Stylized premium indie science fiction game asset, clean rounded hard surface forms, no text, no logos, no ground plane, isolated single object. "
ASSETS = {
    "resident": STYLE + "Friendly bipedal humanoid service robot, full body, two clearly separated arms and legs, hands with simple fingers, articulated elbows and knees, A pose. Pearl ceramic armor, dark navy flexible joints, oval black glass face with two cyan glowing eyes, small orange chest accent. Warm approachable proportions, elegant compact silhouette, practical space station assistant. No weapons, no accessories held in hands.",
    "player": STYLE + "Full body humanoid astronaut explorer in A pose, clearly separated arms and legs, hands with simple fingers. Compact rounded helmet with dark blue glass visor, warm orange and ivory space suit, navy flexible joints, small backpack, sturdy boots. Friendly stylized game character, clean readable silhouette, no weapons, no objects in hands.",
    "station": STYLE + "Freestanding futuristic workstation console for one standing humanoid, waist height, compact wide desk with angled inset cyan display, ivory ceramic panels, navy metal frame, orange corner accents, thick single central pedestal and stable base. Screen is part of the desk, no chair, no wires, no person. Designed for a peaceful orbital research outpost.",
    "beacon": STYLE + "Elegant space outpost navigation beacon tower, tapered dark navy base, stacked ivory ceramic rings, luminous turquoise central energy core, small orange bands. Freestanding compact sci-fi monument with clean strong silhouette, no cables, no people. Solarpunk optimistic futuristic industrial design.",
    "habitat": STYLE + "Small single modular science fiction habitat building, rounded rectangular ivory pod on short dark navy legs, one closed sliding door in front with orange frame, blue panoramic side windows, dark navy roof with small antenna. Peaceful lunar research station, compact one story architectural prop, no terrain, no people, no separate objects.",
    "crates": STYLE + "Single compact futuristic cargo container, rounded rectangular dark navy storage box, ivory reinforcement corners, orange locking bands, recessed cyan small indicator, bevelled edges, sturdy feet. Peaceful space outpost supply crate, no text, closed lid, no other objects.",
}


class NoAPIRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        # urllib otherwise forwards Authorization to a redirect's new host.
        raise urllib.error.HTTPError(request.full_url, code, "API redirects are disabled", headers, fp)


def save(path: Path, data: object) -> None:
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as stream:
        stream.write(json.dumps(data, indent=2) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-credits", type=int, default=999)
    parser.add_argument("--inspect", action="store_true", help="Only check balance and list basic animation IDs")
    args = parser.parse_args()
    if not 1 <= args.max_credits < 1000:
        parser.error("credit ceiling must be between 1 and 999")
    if args.state_dir.resolve().is_relative_to(Path(__file__).resolve().parents[1]):
        parser.error("private state directory must be outside this repository")
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(args.state_dir, 0o700)
    lock = (args.state_dir / "lock").open("w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    key = os.environ.get("MESHY_API_KEY") or getpass.getpass("Meshy API key (hidden): ")
    if not key.startswith("msy_"):
        raise SystemExit("Expected a Meshy API key")
    api_opener = urllib.request.build_opener(NoAPIRedirects())

    def api(path: str, payload: dict | None = None) -> dict | list:
        request = urllib.request.Request(API + path,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        try:
            with api_opener.open(request, timeout=90) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Never log requests/headers or provider bodies which might echo secrets.
            raise RuntimeError(f"Meshy {path.split('?')[0]} returned HTTP {error.code}") from None
        except Exception:  # noqa: BLE001 - provider exceptions must not expose request credentials
            raise RuntimeError("Meshy request did not complete; inspect saved reservation before retrying") from None

    balance = api("/openapi/v1/balance")
    print("Available Meshy credits:", balance.get("balance"), flush=True)
    library = api("/openapi/v1/animations/library")
    if isinstance(library, dict):
        library = library.get("result", library.get("data", []))
    basics = [item for item in library if any(word in str(item.get("name", "")).lower() for word in ("idle", "walk", "waving"))]
    print("Basic animations:", json.dumps([{k: item.get(k) for k in ("action_id", "name", "key")} for item in basics][:35]), flush=True)
    if args.inspect:
        return
    idle = next((item for item in basics if "idle" in item.get("name", "").lower()), None)
    walk = next((item for item in basics if item.get("key") == "Casual_Walk"), None)
    if walk is None:
        walk = next((item for item in basics if "walk" in item.get("name", "").lower() and "back" not in item.get("name", "").lower()), None)
    actions = [item["action_id"] for item in (idle, walk) if item]
    state_path = args.state_dir / "ledger.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {"starting_balance": balance.get("balance"), "tasks": [], "assets": {}}
    args.output.mkdir(parents=True, exist_ok=True)

    def reserved() -> int:
        return sum(max(t["reserved_credits"], t.get("consumed_credits", 0)) for t in state["tasks"])

    if any(type(task.get(field, 0)) is not int or task.get(field, 0) < 0
           for task in state["tasks"] for field in ("reserved_credits", "consumed_credits")):
        raise SystemExit("Invalid credit ledger; reconcile it before restarting")
    if reserved() > args.max_credits:
        raise SystemExit("Saved credit commitments exceed this ceiling; no tasks submitted")

    def submit(name: str, stage: str, endpoint: str, body: dict, cost: int) -> None:
        if reserved() + cost > args.max_credits:
            raise SystemExit("Credit ceiling reached; no further tasks submitted")
        record = {"asset": name, "stage": stage, "endpoint": endpoint, "reserved_credits": cost, "status": "SUBMITTING"}
        state["tasks"].append(record)
        save(state_path, state)  # Reserve BEFORE network I/O, even if submission becomes uncertain.
        response = api(endpoint, body)
        record.update(id=response["result"], status="PENDING")
        save(state_path, state)
        print(f"Submitted {name}/{stage}; credit commitments {reserved()}/{args.max_credits}", flush=True)

    def download(url: str, path: Path) -> None:
        if not url.startswith("https://"):
            raise RuntimeError("Asset must use HTTPS")
        with urllib.request.urlopen(url, timeout=180) as response:
            data = response.read(100_000_001)
        if len(data) > 100_000_000 or (path.suffix == ".glb" and data[:4] != b"glTF"):
            raise RuntimeError("Asset exceeds size limit or is not GLB")
        path.write_bytes(data)

    def download_result(task: dict, response: dict) -> None:
        url = response["model_urls"]["glb"] if task["stage"] == "refine" else response["result"]["animation_glb_url"]
        download(url, args.output / f"{task['asset']}.glb")
        thumb = response.get("thumbnail_url")
        if thumb:
            download(thumb, args.state_dir / f"{task['asset']}.png")

    def publish() -> None:
        public = {"generator": "Meshy", "model": "meshy-t2", "credit_ceiling": args.max_credits,
            "reserved_credits": reserved(), "reported_credits": sum(t.get("consumed_credits", 0) for t in state["tasks"]),
            "tasks": [{k: v for k, v in task.items() if k not in ("response", "endpoint")} for task in state["tasks"]],
            "assets": {name: {"prompt": prompt, "sha256": hashlib.sha256((args.output / f"{name}.glb").read_bytes()).hexdigest()}
                       for name, prompt in ASSETS.items() if (args.output / f"{name}.glb").exists()}}
        save(args.output.parent / "provenance.json", public)

    while True:
        if any(task["status"] == "SUBMITTING" for task in state["tasks"]):
            raise SystemExit("Uncertain submission exists in ledger; reconcile it with Meshy before restarting")
        # A completed task can outlive its local output (a moved output folder,
        # accidental deletion, or interrupted packaging). Recover its download
        # from a fresh read-only task response; never resubmit paid generation.
        for name in ASSETS:
            previous_tasks = [task for task in state["tasks"] if task["asset"] == name]
            latest = previous_tasks[-1] if previous_tasks else None
            if latest and latest["status"] == "SUCCEEDED" \
                    and latest["stage"] in ("refine", "animate") \
                    and not (args.output / f"{name}.glb").is_file():
                response = api(latest["endpoint"] + "/" + latest["id"])
                save(args.state_dir / (latest["id"] + ".json"), response)
                download_result(latest, response)
        for task in state["tasks"]:
            if task["status"] not in ("PENDING", "IN_PROGRESS"):
                continue
            response = api(task["endpoint"] + "/" + task["id"])
            previous = task["status"]
            task["status"] = response["status"]
            task["consumed_credits"] = response.get("consumed_credits", 0)
            save(args.state_dir / (task["id"] + ".json"), response)
            if previous != task["status"]:
                print(f"{task['asset']}/{task['stage']}: {task['status']}", flush=True)
            if task["status"] == "SUCCEEDED" and task["stage"] in ("refine", "animate"):
                download_result(task, response)
        save(state_path, state)
        active = sum(t["status"] in ("PENDING", "IN_PROGRESS") for t in state["tasks"])
        finished = 0
        for name, prompt in ASSETS.items():
            tasks = [t for t in state["tasks"] if t["asset"] == name]
            last = tasks[-1] if tasks else None
            if last and last["status"] in ("FAILED", "CANCELED"):
                finished += 1
                continue
            if last and last["status"] == "SUCCEEDED" and (last["stage"] == "animate" or (last["stage"] == "refine" and name not in ("resident", "player"))):
                finished += 1
                continue
            if active >= 3 or (last and last["status"] != "SUCCEEDED"):
                continue
            if last is None:
                body = {"mode": "preview", "prompt": prompt, "model_type": "smart-topology", "ai_model": "meshy-t2", "topology": "triangle", "target_polycount": 6000 if name in ("resident", "player") else 2500, "target_formats": ["glb"]}
                if name in ("resident", "player"):
                    body["pose_mode"] = "a-pose"
                submit(name, "preview", TEXT, body, 5)
            elif last["stage"] == "preview":
                submit(name, "refine", TEXT, {"mode": "refine", "preview_task_id": last["id"], "texture_prompt": prompt, "enable_pbr": False, "texture_resolution": "2k", "target_formats": ["glb"]}, 10)
            elif last["stage"] == "refine":
                submit(name, "rig", RIG, {"input_task_id": last["id"], "height_meters": 1.7}, 5)
            elif last["stage"] == "rig":
                if not actions:
                    raise SystemExit("No suitable animation IDs returned")
                submit(name, "animate", ANIMATE, {"rig_task_id": last["id"], "action_ids": actions}, 3 * len(actions))
            active += 1
        publish()
        if finished == len(ASSETS):
            print(f"Finished. Credit commitments: {reserved()}; assets: {len(list(args.output.glob('*.glb')))}", flush=True)
            print("Remaining Meshy balance:", api("/openapi/v1/balance").get("balance"), flush=True)
            break
        time.sleep(15)


if __name__ == "__main__":
    main()
