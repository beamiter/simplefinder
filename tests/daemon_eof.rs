//! A JSONL client commonly writes its requests and then closes stdin before it
//! starts consuming stdout. EOF ends the request stream; it must not cancel a
//! request the daemon has already accepted or discard its queued reply.

use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

#[test]
fn an_accepted_file_request_survives_stdin_eof() {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
    let root =
        std::env::temp_dir().join(format!("simplefinder-eof-{}-{unique}", std::process::id()));
    std::fs::create_dir_all(&root).expect("a temporary search root");
    // Enough work that the request remains in flight when the input loop sees
    // EOF, without making the regression test meaningfully slow.
    for index in 0..512 {
        std::fs::write(root.join(format!("file-{index:04}.txt")), "needle\n")
            .expect("a file in the temporary search root");
    }

    let mut child = Command::new(env!("CARGO_BIN_EXE_simplefinder-daemon"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("the daemon binary this test was built alongside");
    let request = serde_json::json!({
        "type": "files",
        "id": 77,
        "root": root,
        "query": "file",
        "max": 10,
        "no_ignore": true,
    });
    writeln!(child.stdin.take().expect("piped stdin"), "{request}")
        .expect("the request reaches the daemon");

    let output = child
        .wait_with_output()
        .expect("the daemon exits after EOF");
    std::fs::remove_dir_all(&root).ok();
    assert!(
        output.status.success(),
        "daemon failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let line = String::from_utf8(output.stdout).expect("daemon output is UTF-8");
    let event: serde_json::Value =
        serde_json::from_str(line.trim()).expect("one complete JSON reply after EOF");
    assert_eq!(event["type"], "files_result");
    assert_eq!(event["id"], 77);
    assert_eq!(event["done"], true);
    assert_eq!(event["items"].as_array().map(Vec::len), Some(10));
}

#[test]
fn shutdown_is_bounded_when_stdout_is_not_consumed() {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!(
        "simplefinder-eof-backpressure-{}-{unique}",
        std::process::id()
    ));
    std::fs::create_dir_all(&root).expect("a temporary search root");
    for index in 0..5_000 {
        std::fs::write(root.join(format!("long-result-name-{index:04}.txt")), b"x")
            .expect("a search result fixture");
    }

    let mut child = Command::new(env!("CARGO_BIN_EXE_simplefinder-daemon"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("the daemon binary this test was built alongside");
    let request = serde_json::json!({
        "type": "files",
        "id": 88,
        "root": root,
        "query": "result",
        "max": 5000,
        "no_ignore": true,
    });
    writeln!(child.stdin.take().expect("piped stdin"), "{request}")
        .expect("the request reaches the daemon");

    // Deliberately retain but do not read stdout.  The result is larger than a
    // pipe buffer, so only the writer deadline can finish shutdown.
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().expect("poll daemon") {
            break status;
        }
        if started.elapsed() > Duration::from_secs(10) {
            let _ = child.kill();
            let _ = child.wait();
            std::fs::remove_dir_all(&root).ok();
            panic!("daemon did not bound EOF shutdown under stdout backpressure");
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    std::fs::remove_dir_all(&root).ok();
    assert!(status.success(), "daemon exited unsuccessfully: {status}");
}

#[test]
fn input_loop_cannot_block_before_observing_eof() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_simplefinder-daemon"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("the daemon binary this test was built alongside");
    {
        let stdin = child.stdin.as_mut().unwrap();
        let mut sent = 0;
        for id in 1..=6_000 {
            match writeln!(stdin, "{}", serde_json::json!({"type": "ping", "id": id})) {
                Ok(()) => sent += 1,
                Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => break,
                Err(error) => panic!("could not write request flood: {error}"),
            }
        }
        assert!(
            sent > 4096,
            "fixture never exceeded the reply channel capacity"
        );
    }
    drop(child.stdin.take());

    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().expect("poll daemon") {
            break status;
        }
        if started.elapsed() > Duration::from_secs(10) {
            let _ = child.kill();
            let _ = child.wait();
            panic!("reply backpressure stopped the input loop before EOF");
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    assert!(status.success(), "daemon exited unsuccessfully: {status}");
}
