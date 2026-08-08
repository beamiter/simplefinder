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
                                         picked by the request's pattern.

Batches for pattern `needle` (gates 1..3)
  1. b.txt, c.txt                      done:false   -- first paint
  2. a.txt, b.txt, c.txt               done:false   -- a match found late that
                                                      sorts *above* the others
  3. a.txt, b.txt, c.txt, d.txt        done:true    -- 4 of 12, count inexact

Batches for pattern `viewport` (gates 4..5)
  4. f00.txt .. f39.txt                done:false   -- more results than the
                                                      panel can show at once
  5. a00.txt + f00.txt .. f39.txt      done:true    -- one row inserted above
                                                      a scrolled viewport

Any other pattern answers once with no results, so a stray request cannot hang
the test waiting for a gate that will never open.

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

# A result set taller than the panel, so the viewport can be scrolled away from
# the top before the next batch lands.
MANY = [item("f%02d.txt" % n, "fff viewport") for n in range(40)]
FIRST = item("a00.txt", "aaa viewport")

# (items, done, total, capped, total_exact)
BATCHES = [
    ([B, C], False, 2, False, True),
    ([A, B, C], False, 3, False, True),
    ([A, B, C, D], True, 12, True, False),
]

VIEWPORT_BATCHES = [
    (MANY, False, len(MANY), False, True),
    ([FIRST] + MANY, True, len(MANY) + 1, False, True),
]

# pattern -> (gate index of the first batch, batches)
SEQUENCES = {
    "needle": (1, BATCHES),
    "viewport": (4, VIEWPORT_BATCHES),
}


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
            first_gate, batches = SEQUENCES.get(req.get("pattern", ""), (0, None))
            if not req.get("stream") or batches is None:
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
            for index, (items, done, total, capped, exact) in enumerate(
                batches, first_gate
            ):
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
