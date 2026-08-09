//! The `file_cache` field of a `grep` request, driven through the real daemon.
//!
//! `g:simplefinder_grep_cache = 0` promises that a grep neither reads nor
//! writes the file finder's cached list of the tree, and half of keeping that
//! promise lives in `serve()`: it looks the cache up only when the request
//! asked for it, and hands the flag to `handle_grep_sync`, which is what
//! decides whether the walk hands its list back to be published.  The unit
//! tests reach `handle_grep_sync` directly with the flag already set, and
//! `tests/vim_cache.vim` only asserts on the JSON the plugin sends, so nothing
//! covered the wiring in between: setting `file_cache: true` there passed the
//! whole suite while every grep published its list into a cache the user had
//! opted out of, leaving a later `:SimpleFinderFiles` to be served a list up
//! to CACHE_TTL_SECS stale.
//!
//! These tests pin both halves from both sides, over the wire the plugin
//! actually speaks.  A file created *after* a walk is the probe: it is visible
//! to the next request exactly when that request walked rather than read the
//! shared list.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::Duration;

/// Generous: this only has to be shorter than a human's patience and longer
/// than a walk of two files on a loaded machine.  Its job is to turn a daemon
/// that answers nothing into a failure instead of a `make check` that hangs.
const REPLY_TIMEOUT: Duration = Duration::from_secs(30);

// ─────────────────── a directory to search ───────────────────

struct Tree {
    path: PathBuf,
}

impl Tree {
    fn new(label: &str) -> Tree {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "simplefinder-{label}-{}-{unique}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("a temporary directory to search");
        Tree { path }
    }

    fn write(&self, name: &str, contents: &str) {
        std::fs::write(self.path.join(name), contents).expect("a file in the temporary directory");
    }

    fn root(&self) -> String {
        self.path.to_str().expect("a UTF-8 temporary path").into()
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

// ─────────────────── the daemon, over its own protocol ───────────────────

struct Daemon {
    child: Child,
    stdin: ChildStdin,
    events: Receiver<String>,
}

impl Daemon {
    fn start() -> Daemon {
        let mut child = Command::new(env!("CARGO_BIN_EXE_simplefinder-daemon"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("the daemon binary this test was built alongside");
        let stdout = child.stdout.take().expect("a piped stdout");
        let stdin = child.stdin.take().expect("a piped stdin");
        // Read on a thread so a daemon that says nothing hits the deadline in
        // wait_for() instead of blocking this one for ever.
        let (tx, events) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Daemon {
            child,
            stdin,
            events,
        }
    }

    fn send(&mut self, request: &serde_json::Value) {
        writeln!(self.stdin, "{request}").expect("the daemon to accept a request");
        self.stdin.flush().expect("the request to reach the daemon");
    }

    /// The first `done: true` event of this type, or a failure.  Streamed
    /// batches and events of other requests are skipped, so a caller reads the
    /// answer it asked for and nothing else.
    fn wait_for(&self, kind: &str) -> serde_json::Value {
        loop {
            let line = match self.events.recv_timeout(REPLY_TIMEOUT) {
                Ok(line) => line,
                Err(RecvTimeoutError::Timeout) => panic!("no {kind} within {REPLY_TIMEOUT:?}"),
                Err(RecvTimeoutError::Disconnected) => {
                    panic!("the daemon exited before its {kind}")
                }
            };
            let event: serde_json::Value =
                serde_json::from_str(&line).expect("every daemon event is one JSON object");
            assert_ne!(
                event["type"], "error",
                "the daemon reported an error: {line}"
            );
            if event["type"] == kind && event["done"] == true {
                return event;
            }
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn grep_request(id: u64, root: &str, file_cache: bool) -> serde_json::Value {
    serde_json::json!({
        "type": "grep",
        "id": id,
        "root": root,
        "pattern": "needle",
        // no_ignore keeps a stray global gitignore from deciding what this
        // test sees; both requests below share it, so they share a cache key.
        "no_ignore": true,
        "file_cache": file_cache,
    })
}

fn files_request(id: u64, root: &str) -> serde_json::Value {
    serde_json::json!({
        "type": "files",
        "id": id,
        "root": root,
        "query": "",
        "no_ignore": true,
    })
}

fn paths(event: &serde_json::Value) -> Vec<String> {
    event["items"]
        .as_array()
        .expect("a result carries items")
        .iter()
        .map(|item| item["path"].as_str().expect("a path is a string").into())
        .collect()
}

// ─────────────────── the tests ───────────────────

/// `file_cache: false` -- the opt-out -- must leave the shared cache alone, so
/// the next `files` request walks and sees the tree as it is now.
#[test]
fn a_grep_that_opted_out_does_not_publish_its_walk() {
    let tree = Tree::new("cache-off");
    tree.write("alpha.txt", "needle\n");
    let mut daemon = Daemon::start();

    daemon.send(&grep_request(1, &tree.root(), false));
    let grep = daemon.wait_for("grep_result");
    assert_eq!(paths(&grep), vec!["alpha.txt"], "the grep walked the tree");

    // Created after the walk: it can only be seen by a walk that runs now.
    tree.write("beta.txt", "");
    daemon.send(&files_request(2, &tree.root()));
    let files = daemon.wait_for("files_result");
    assert_eq!(
        paths(&files),
        vec!["alpha.txt", "beta.txt"],
        "a grep sent file_cache:false must not have published its file list, \
         or the file finder is served the very cache the user opted out of"
    );
}

/// The other side of the same wire: `file_cache: true` is what
/// `g:simplefinder_grep_cache` leaves on by default, and it is worth having
/// only if the grep's walk really does spare the next request its own.
#[test]
fn a_grep_that_asked_for_the_cache_publishes_its_walk() {
    let tree = Tree::new("cache-on");
    tree.write("alpha.txt", "needle\n");
    let mut daemon = Daemon::start();

    daemon.send(&grep_request(1, &tree.root(), true));
    let grep = daemon.wait_for("grep_result");
    assert_eq!(paths(&grep), vec!["alpha.txt"], "the grep walked the tree");

    tree.write("beta.txt", "");
    daemon.send(&files_request(2, &tree.root()));
    let files = daemon.wait_for("files_result");
    assert_eq!(
        paths(&files),
        vec!["alpha.txt"],
        "the file finder is served the list the grep published, which is the \
         walk this option exists to save"
    );
}

/// The reading half of the same opt-out: a grep that did not ask for the
/// shared list must walk, even when a `files` request has just filled it in.
#[test]
fn a_grep_that_opted_out_does_not_read_the_shared_list() {
    let tree = Tree::new("read-off");
    tree.write("alpha.txt", "needle\n");
    let mut daemon = Daemon::start();

    daemon.send(&files_request(1, &tree.root()));
    let files = daemon.wait_for("files_result");
    assert_eq!(paths(&files), vec!["alpha.txt"], "the file finder walked");

    // Created after that walk, so only a grep of its own can find it.
    tree.write("beta.txt", "needle\n");
    daemon.send(&grep_request(2, &tree.root(), false));
    let grep = daemon.wait_for("grep_result");
    assert_eq!(
        paths(&grep),
        vec!["alpha.txt", "beta.txt"],
        "a grep sent file_cache:false must walk, not search a list it never \
         asked for -- searching a stale one silently loses matches"
    );
}

/// And with the option left on, the point of the cache: the grep searches the
/// list the file finder already walked for instead of walking again.
#[test]
fn a_grep_that_asked_for_the_cache_reads_the_shared_list() {
    let tree = Tree::new("read-on");
    tree.write("alpha.txt", "needle\n");
    let mut daemon = Daemon::start();

    daemon.send(&files_request(1, &tree.root()));
    let files = daemon.wait_for("files_result");
    assert_eq!(paths(&files), vec!["alpha.txt"], "the file finder walked");

    tree.write("beta.txt", "needle\n");
    daemon.send(&grep_request(2, &tree.root(), true));
    let grep = daemon.wait_for("grep_result");
    assert_eq!(
        paths(&grep),
        vec!["alpha.txt"],
        "the grep searched the file finder's list, which is what makes a \
         keystroke cost one read of known files instead of a fresh walk"
    );
}
