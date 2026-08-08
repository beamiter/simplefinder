#!/usr/bin/env python3
"""A daemon that records what the plugin asked for, for tests/vim_cache.vim.

Whether an optional feature is used is a property of the *request*, and the
real daemon gives no way to see one: it answers the same way either way, only
faster.  This stand-in writes every request it receives to a file so a test can
assert on the negotiation itself — that a field is set when the capability is
advertised, and unset when it is not — rather than on a timing difference that
would make the test either flaky or unfalsifiable.

Requests
  {"type":"ping","id":N}    -> pong, protocol 4, the capabilities in FAKE_CAPS
  anything else             -> one empty done:true result of the matching type

Environment
  FAKE_LOG   file to append each received request to, one JSON object per line
  FAKE_CAPS  comma-separated capability names to advertise; unset means the
             full set this plugin knows about
"""

import json
import os
import sys

ALL_CAPS = ["files", "grep", "cancel", "match_indices", "path_globs", "stream", "grep_cache"]


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def record(line):
    path = os.environ.get("FAKE_LOG")
    if not path:
        return
    # Opened per request and flushed: the test reads this file while the daemon
    # is still running, so a buffered handle would show it nothing.
    with open(path, "a") as handle:
        handle.write(line + "\n")
        handle.flush()


def main():
    caps = os.environ.get("FAKE_CAPS")
    names = ALL_CAPS if caps is None else [c for c in caps.split(",") if c]
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        record(line)

        kind = req.get("type")
        if kind == "ping":
            emit(
                {
                    "type": "pong",
                    "id": req.get("id", 0),
                    "protocol_version": 4,
                    "version": "fake",
                    "capabilities": {name: True for name in names},
                }
            )
        elif kind in ("grep", "files"):
            emit(
                {
                    "type": kind + "_result",
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
