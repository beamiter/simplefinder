#!/usr/bin/env python3
"""A special-file preview must not block the editor (use an isolated Vim)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


def run_case(folder, target, expected, loaded=False):
    script = folder / "case.vim"
    result = folder / "result"
    result.unlink(missing_ok=True)
    setup = ""
    if loaded:
        setup = f"enew\nexecute 'file ' .. fnameescape({quoted(target)})\ncall setline(1, 'memory preview')\n"
    script.write_text(f"""set nocompatible nomore
let &runtimepath = {quoted(ROOT)} .. ',' .. &runtimepath
let g:simplefinder_panel_width = 30
let g:simplefinder_preview = 1
runtime plugin/simplefinder.vim
{setup}
call simplefinder#Pick({{'items': [{{'path': {quoted(target)}}}]}})
sleep 100m
let lines = []
for id in popup_list()
  call extend(lines, getbufline(winbufnr(id), 1, '$'))
endfor
call writefile(lines, {quoted(result)})
qa!
""", encoding="utf-8")
    try:
        # subprocess.run kills/reaps Vim on timeout, even if it handles SIGTERM.
        completed = subprocess.run(
            ["vim", "-Nu", "NONE", "-n", "-i", "NONE", "-es", "-S", str(script)],
            capture_output=True, timeout=10, check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise AssertionError(f"preview blocked on {target.name}") from error
    assert completed.returncode == 0, (target, completed.stderr)
    assert result.exists(), f"Vim did not complete preview for {target.name}"
    text = result.read_text(encoding="utf-8")
    if expected is None:
        assert not text, f"special file unexpectedly opened a preview: {text!r}"
    else:
        assert expected in text, (target, text)


def main():
    if os.name != "posix" or not hasattr(os, "mkfifo"):
        print("SKIP special preview: POSIX FIFOs unavailable")
        return
    assert shutil.which("vim"), "Vim is required"
    with tempfile.TemporaryDirectory() as directory:
        folder = Path(directory)
        regular = folder / "ordinary.txt"
        regular.write_text("ordinary preview\n", encoding="utf-8")
        fifo = folder / "pipe"
        os.mkfifo(fifo)
        regular_link = folder / "regular-link.txt"
        regular_link.symlink_to(regular)
        fifo_link = folder / "pipe-link"
        fifo_link.symlink_to(fifo)
        run_case(folder, regular, "ordinary preview")
        run_case(folder, regular_link, "ordinary preview")
        run_case(folder, fifo, None)
        run_case(folder, fifo_link, None)
        dangling = folder / "dangling"
        dangling.symlink_to(folder / "missing")
        self_loop = folder / "self-loop"
        self_loop.symlink_to(self_loop)
        loop_a, loop_b = folder / "loop-a", folder / "loop-b"
        loop_a.symlink_to(loop_b)
        loop_b.symlink_to(loop_a)
        for target in [dangling, self_loop, loop_a]:
            run_case(folder, target, None)
        run_case(folder, folder, None)
        if Path("/dev/null").is_char_device():
            run_case(folder, Path("/dev/null"), None)
        run_case(folder, fifo, "memory preview", loaded=True)
        print("PASS special-file previews, symlinks and loaded-buffer authority")


if __name__ == "__main__":
    main()
