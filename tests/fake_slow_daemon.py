#!/usr/bin/env python3
"""A daemon that is slow to shake hands, for tests/vim_negotiate.vim.

The plugin holds a search raised before the pong comes back and re-dispatches
it once capabilities are known, with a 2 second budget.  Every interesting case
lives inside that window, which the real daemon closes in milliseconds -- so
this stand-in simply does not answer the ping until told to.

Requests
  {"type":"ping","id":N}   -> pong (protocol 4, full capabilities), but only
                              once FAKE_PONG_GATE exists; without the gate it
                              never answers at all.
  {"type":"grep","id":N}   -> one empty done:true reply, so a request that does
                              get through is visible in the panel.

Environment
  FAKE_SPAWN_LOG   every process appends its pid here on start, so a test can
                   tell "still the same daemon" from "a second one was
                   started" -- the plugin restarting a daemon the user stopped
                   is exactly what tests/vim_negotiate.vim is about.
  FAKE_PONG_GATE   path the ping waits for before it is answered.
"""

import json
import os
import sys
import time


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    log = os.environ.get("FAKE_SPAWN_LOG")
    if log:
        with open(log, "a") as handle:
            handle.write("%d\n" % os.getpid())

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue

        kind = req.get("type")
        if kind == "ping":
            gate = os.environ.get("FAKE_PONG_GATE")
            # A bounded wait: a broken test must not hang the suite forever.
            deadline = time.monotonic() + 30.0
            while time.monotonic() < deadline:
                if gate and os.path.exists(gate):
                    break
                time.sleep(0.01)
            else:
                continue
            emit(
                {
                    "type": "pong",
                    "id": req.get("id", 0),
                    "protocol_version": 4,
                    "version": "slow",
                    "capabilities": {
                        "files": True,
                        "grep": True,
                        "cancel": True,
                        "match_indices": True,
                        "path_globs": True,
                        "stream": True,
                    },
                }
            )
        elif kind == "grep":
            emit(
                {
                    "type": "grep_result",
                    "id": req.get("id", 0),
                    "items": [],
                    "done": True,
                    "total": 0,
                    "capped": False,
                    "total_exact": True,
                    "elapsed_ms": 1,
                }
            )


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
