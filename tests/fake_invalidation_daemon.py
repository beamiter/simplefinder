#!/usr/bin/env python3
"""Records negotiation and deliberately emits a retired result after mutating."""
import json
import os
import sys
import time


def emit(kind, ident, **data):
    print(json.dumps(dict(type=kind, id=ident, **data)), flush=True)


current = None
switch_root = os.environ.get("INVALIDATION_SWITCH_ROOT")
switch_barrier = os.environ.get("INVALIDATION_SWITCH_BARRIER")
held = None


def wait_for_gate(suffix):
    deadline = time.monotonic() + 3.0
    while not os.path.isfile(switch_barrier + suffix):
        if time.monotonic() >= deadline:
            raise RuntimeError("project-switch test did not open its reply gate")
        time.sleep(0.005)


for line in sys.stdin:
    req = json.loads(line)
    kind, ident = req["type"], req.get("id", 0)
    with open(os.environ["INVALIDATION_LOG"], "a", encoding="utf-8") as log:
        log.write(json.dumps(req) + "\n")
    if kind == "ping":
        caps = {"files": True, "cancel": True}
        if os.environ.get("INVALIDATION_CAP") == "1":
            caps["invalidate_files"] = True
        emit("pong", ident, protocol_version=4, version="test", capabilities=caps)
    elif kind == "files":
        current = (ident, req["root"])
        if held:
            if current[1] != switch_root:
                # Both the original search and its replacement are still in
                # flight at the moment project B opens.
                held[1].append(ident)
                continue
            wait_for_gate(".release-a")
            emit("files_invalidated", held[0])
            for stale_id in held[1]:
                emit("files_result", stale_id, done=True, total=1,
                     items=[{"path": "A-LATE-RESULT.txt", "score": 0}])
            with open(switch_barrier + ".a-sent", "w", encoding="utf-8"):
                pass
            wait_for_gate(".finish-b")
            emit("files_result", ident, done=True, total=1,
                 items=[{"path": "B-COMPLETE.txt", "score": 0}])
            held = None
    elif kind == "invalidate_files":
        if switch_root and current:
            held = (ident, [current[0]])
            continue
        emit("files_invalidated", ident)
        if current and any(os.path.commonpath([current[1], path]) == current[1]
                           for path in req["paths"]):
            emit("files_result", current[0], done=True, total=1,
                 items=[{"path": "STALE-RETIRED-RESULT.txt", "score": 0}])
