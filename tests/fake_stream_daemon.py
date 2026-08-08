#!/usr/bin/env python3
"""A grep daemon that streams on cue, for tests/vim_stream.vim.

The real daemon streams whenever the walk is slow enough, which is exactly the
condition a test cannot arrange reliably.  This stand-in speaks the same wire
format and emits its partial batches one at a time, each one gated on a file
the test creates, so every assertion runs against a known panel state instead
of a race.

Requests
  {"type":"ping","id":N}              -> pong, protocol 4, `stream` capability
  {"type":"grep","id":N,"stream":X}   -> if X is false, one done:true reply
                                         with no results, which is how a
                                         daemon that cannot stream behaves;
                                         otherwise the gated batch sequence
                                         below.

Batches (streaming)
  1. b.txt, c.txt                      done:false   -- first paint
  2. a.txt, b.txt, c.txt               done:false   -- a match found late that
                                                      sorts *above* the others
  3. a.txt, b.txt, c.txt, d.txt        done:true    -- 4 of 12, count inexact

Environment
  FAKE_GATE  path prefix; batch K waits for <prefix>.K before it is sent
"""

import json
import os
import sys
import time


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def item(path, text):
    return {"path": path, "lnum": 1, "col": 1, "col_end": 7, "text": text}


A = item("a.txt", "aaa needle")
B = item("b.txt", "bbb needle")
C = item("c.txt", "ccc needle")
D = item("d.txt", "ddd needle")

# (items, done, total, capped, total_exact)
BATCHES = [
    ([B, C], False, 2, False, True),
    ([A, B, C], False, 3, False, True),
    ([A, B, C, D], True, 12, True, False),
]


def wait_for_gate(index):
    gate = os.environ.get("FAKE_GATE")
    if not gate:
        return
    path = "%s.%d" % (gate, index)
    # The test drives the clock here; a bounded wait keeps a broken test from
    # hanging the suite forever.
    deadline = time.monotonic() + 10.0
    while not os.path.exists(path) and time.monotonic() < deadline:
        time.sleep(0.01)


def main():
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
            emit(
                {
                    "type": "pong",
                    "id": req.get("id", 0),
                    "protocol_version": 4,
                    "version": "fake",
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
            ident = req.get("id", 0)
            if not req.get("stream"):
                emit(
                    {
                        "type": "grep_result",
                        "id": ident,
                        "items": [],
                        "done": True,
                        "total": 0,
                        "capped": False,
                        "total_exact": True,
                        "elapsed_ms": 1,
                    }
                )
                continue
            for index, (items, done, total, capped, exact) in enumerate(BATCHES, 1):
                wait_for_gate(index)
                emit(
                    {
                        "type": "grep_result",
                        "id": ident,
                        "items": items,
                        "done": done,
                        "total": total,
                        "capped": capped,
                        "total_exact": exact,
                        "elapsed_ms": index,
                    }
                )


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
