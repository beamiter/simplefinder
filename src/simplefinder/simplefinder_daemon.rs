use grep_matcher::Matcher;
use grep_searcher::{Searcher, sinks::UTF8};
use ignore::WalkBuilder;
use nucleo_matcher::{
    Config, Matcher as NucleoMatcher, Utf32Str,
    pattern::{CaseMatching, Normalization, Pattern},
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::PathBuf, sync::Arc, time::Instant};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::RwLock,
};
use tokio_util::sync::CancellationToken;

// ─────────────────── Protocol ───────────────────

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "files")]
    Files {
        id: u64,
        root: String,
        #[serde(default)]
        query: String,
        #[serde(default = "default_max")]
        max: usize,
        #[serde(default)]
        hidden: bool,
        #[serde(default)]
        no_ignore: bool,
    },
    #[serde(rename = "grep")]
    Grep {
        id: u64,
        root: String,
        pattern: String,
        #[serde(default)]
        regex: bool,
        #[serde(default)]
        ignore_case: bool,
        #[serde(default = "default_max")]
        max: usize,
        #[serde(default)]
        hidden: bool,
        #[serde(default)]
        no_ignore: bool,
    },
    #[serde(rename = "cancel")]
    Cancel { id: u64 },
}

fn default_max() -> usize {
    200
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "files_result")]
    FilesResult {
        id: u64,
        items: Vec<FileItem>,
        done: bool,
        total: usize,
        capped: bool,
        elapsed_ms: u128,
    },
    #[serde(rename = "grep_result")]
    GrepResult {
        id: u64,
        items: Vec<GrepItem>,
        done: bool,
        total: usize,
        capped: bool,
        elapsed_ms: u128,
    },
    #[serde(rename = "error")]
    Error { id: u64, message: String },
}

#[derive(Debug, Serialize, Clone)]
struct FileItem {
    path: String,
    score: i64,
}

#[derive(Debug, Serialize, Clone)]
struct GrepItem {
    path: String,
    lnum: usize,
    col: usize,
    text: String,
}

// ─────────────────── File cache ───────────────────

const CACHE_TTL_SECS: u64 = 30;

struct CacheEntry {
    files: Arc<Vec<String>>,
    created: Instant,
}

type FileCache = Arc<RwLock<HashMap<String, CacheEntry>>>;

async fn get_or_walk_files(
    cache: &FileCache,
    root: &str,
    hidden: bool,
    no_ignore: bool,
    token: &CancellationToken,
) -> Result<Option<Arc<Vec<String>>>, String> {
    let root_path = validate_root(root)?;
    let cache_key = format!("{}\0{hidden}\0{no_ignore}", root_path.to_string_lossy());

    // Check cache first (with TTL)
    {
        let c = cache.read().await;
        if let Some(entry) = c.get(&cache_key) {
            if entry.created.elapsed().as_secs() < CACHE_TTL_SECS {
                return Ok(Some(Arc::clone(&entry.files)));
            }
        }
    }

    // Walk in blocking thread to avoid stalling the async runtime
    let token_clone = token.clone();
    let files = tokio::task::spawn_blocking(move || {
        let mut builder = WalkBuilder::new(&root_path);
        builder.hidden(!hidden);
        if no_ignore {
            builder
                .ignore(false)
                .git_ignore(false)
                .git_global(false)
                .git_exclude(false);
        }
        let walker = builder.build();

        let mut files = Vec::new();
        for entry in walker {
            if token_clone.is_cancelled() {
                return None;
            }
            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };
            if !entry.file_type().is_some_and(|ft| ft.is_file()) {
                continue;
            }
            if let Ok(rel) = entry.path().strip_prefix(&root_path) {
                files.push(rel.to_string_lossy().into_owned());
            }
        }
        files.sort();
        Some(files)
    })
    .await
    .map_err(|e| format!("file scan failed: {e}"))?;

    let Some(files) = files else {
        return Ok(None);
    };

    let files = Arc::new(files);
    {
        let mut c = cache.write().await;
        c.insert(
            cache_key,
            CacheEntry {
                files: Arc::clone(&files),
                created: Instant::now(),
            },
        );
    }
    Ok(Some(files))
}

fn validate_root(root: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(root);
    let canonical = path
        .canonicalize()
        .map_err(|e| format!("cannot access root {root:?}: {e}"))?;
    if !canonical.is_dir() {
        return Err(format!("search root is not a directory: {root}"));
    }
    Ok(canonical)
}

// ─────────────────── Fuzzy matching ───────────────────

fn fuzzy_filter(
    files: &[String],
    query: &str,
    max: usize,
    token: &CancellationToken,
) -> Option<(Vec<FileItem>, usize)> {
    if query.is_empty() {
        let items = files
            .iter()
            .take(max)
            .map(|p| FileItem {
                path: p.clone(),
                score: 0,
            })
            .collect();
        return Some((items, files.len()));
    }

    let mut matcher = NucleoMatcher::new(Config::DEFAULT);
    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);

    let mut scored: Vec<FileItem> = Vec::new();
    for (index, p) in files.iter().enumerate() {
        if index % 1024 == 0 && token.is_cancelled() {
            return None;
        }
        if let Some(score) = {
            let mut buf = Vec::new();
            let haystack = Utf32Str::new(p, &mut buf);
            pattern.score(haystack, &mut matcher)
        } {
            scored.push(FileItem {
                path: p.clone(),
                score: score as i64,
            });
        }
    }

    let total = scored.len();
    scored.sort_unstable_by(|a, b| b.score.cmp(&a.score).then_with(|| a.path.cmp(&b.path)));
    scored.truncate(max);
    Some((scored, total))
}

// ─────────────────── Grep ───────────────────

#[derive(Clone, Copy)]
struct GrepOptions {
    is_regex: bool,
    ignore_case: bool,
    max: usize,
    hidden: bool,
    no_ignore: bool,
}

fn handle_grep_sync(
    root: &str,
    pattern: &str,
    options: GrepOptions,
    token: &CancellationToken,
) -> Result<(Vec<GrepItem>, bool), String> {
    let expression = if options.is_regex {
        pattern.to_string()
    } else {
        regex_syntax::escape(pattern)
    };
    let matcher = grep_regex::RegexMatcherBuilder::new()
        .case_insensitive(options.ignore_case)
        .build(&expression)
        .map_err(|e| e.to_string())?;

    let root_path = validate_root(root)?;
    let results: Arc<std::sync::Mutex<Vec<GrepItem>>> = Arc::new(std::sync::Mutex::new(Vec::new()));
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let mut builder = WalkBuilder::new(&root_path);
    builder
        .hidden(!options.hidden)
        .threads(num_cpus::get().min(8));
    if options.no_ignore {
        builder
            .ignore(false)
            .git_ignore(false)
            .git_global(false)
            .git_exclude(false);
    }
    let walker = builder.build_parallel();

    walker.run(|| {
        let matcher = matcher.clone();
        let root_path = root_path.to_path_buf();
        let results = Arc::clone(&results);
        let done = Arc::clone(&done);
        let token = token.clone();
        let mut searcher = Searcher::new();

        Box::new(move |entry| {
            if token.is_cancelled() || done.load(std::sync::atomic::Ordering::Relaxed) {
                return ignore::WalkState::Quit;
            }

            let entry = match entry {
                Ok(e) => e,
                Err(_) => return ignore::WalkState::Continue,
            };
            if !entry.file_type().is_some_and(|ft| ft.is_file()) {
                return ignore::WalkState::Continue;
            }

            let path = entry.path().to_path_buf();
            let rel = path
                .strip_prefix(&root_path)
                .unwrap_or(&path)
                .to_string_lossy()
                .into_owned();

            let mut local_items = Vec::new();
            let _ = searcher.search_path(
                &matcher,
                &path,
                UTF8(|lnum, line| {
                    let col = matcher
                        .find(line.as_bytes())
                        .ok()
                        .flatten()
                        .map(|m| m.start() + 1)
                        .unwrap_or(1);
                    local_items.push(GrepItem {
                        path: rel.clone(),
                        lnum: lnum as usize,
                        col,
                        text: line.trim_end().to_string(),
                    });
                    Ok(!token.is_cancelled() && local_items.len() <= options.max)
                }),
            );

            if !local_items.is_empty() {
                let mut r = results.lock().unwrap();
                r.extend(local_items);
                if r.len() > options.max {
                    done.store(true, std::sync::atomic::Ordering::Relaxed);
                    return ignore::WalkState::Quit;
                }
            }

            ignore::WalkState::Continue
        })
    });

    let mut results = results.lock().unwrap();
    let capped = results.len() > options.max;
    results.truncate(options.max);
    results.sort_unstable_by(|a, b| {
        a.path
            .cmp(&b.path)
            .then_with(|| a.lnum.cmp(&b.lnum))
            .then_with(|| a.col.cmp(&b.col))
    });
    Ok((std::mem::take(&mut *results), capped))
}

// ─────────────────── stdout writer ───────────────────

type EventTx = tokio::sync::mpsc::Sender<String>;

async fn stdout_writer(mut rx: tokio::sync::mpsc::Receiver<String>) {
    let mut out = tokio::io::stdout();
    while let Some(line) = rx.recv().await {
        if out.write_all(line.as_bytes()).await.is_err() {
            break;
        }
        if out.write_all(b"\n").await.is_err() {
            break;
        }
        let _ = out.flush().await;
    }
}

async fn send_event(tx: &EventTx, evt: &Event) {
    if let Ok(line) = serde_json::to_string(evt) {
        let _ = tx.send(line).await;
    }
}

// ─────────────────── Main ───────────────────

#[tokio::main(flavor = "multi_thread")]
async fn main() -> std::io::Result<()> {
    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();

    let (out_tx, out_rx) = tokio::sync::mpsc::channel::<String>(4096);
    tokio::spawn(stdout_writer(out_rx));

    let cancels: Arc<RwLock<HashMap<u64, CancellationToken>>> =
        Arc::new(RwLock::new(HashMap::new()));

    let file_cache: FileCache = Arc::new(RwLock::new(HashMap::new()));

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let req = match serde_json::from_str::<Request>(&line) {
            Ok(r) => r,
            Err(e) => {
                send_event(
                    &out_tx,
                    &Event::Error {
                        id: 0,
                        message: format!("invalid request: {e}"),
                    },
                )
                .await;
                continue;
            }
        };

        match req {
            Request::Cancel { id } => {
                let map = cancels.read().await;
                if let Some(token) = map.get(&id) {
                    token.cancel();
                }
            }
            Request::Files {
                id,
                root,
                query,
                max,
                hidden,
                no_ignore,
            } => {
                let tx = out_tx.clone();
                let cancels = cancels.clone();
                let cache = file_cache.clone();
                let token = CancellationToken::new();
                {
                    let mut map = cancels.write().await;
                    map.insert(id, token.clone());
                }

                tokio::spawn(async move {
                    let started = Instant::now();
                    let files =
                        match get_or_walk_files(&cache, &root, hidden, no_ignore, &token).await {
                            Ok(Some(f)) => f,
                            Ok(None) => {
                                // Cancelled during walk
                                let mut map = cancels.write().await;
                                map.remove(&id);
                                return;
                            }
                            Err(message) => {
                                send_event(&tx, &Event::Error { id, message }).await;
                                let mut map = cancels.write().await;
                                map.remove(&id);
                                return;
                            }
                        };

                    if token.is_cancelled() {
                        let mut map = cancels.write().await;
                        map.remove(&id);
                        return;
                    }

                    let max = max.min(5_000);
                    let token_clone = token.clone();
                    let result = tokio::task::spawn_blocking(move || {
                        fuzzy_filter(&files, &query, max, &token_clone)
                    })
                    .await;
                    let (items, total) = match result {
                        Ok(Some(result)) => result,
                        Ok(None) => {
                            let mut map = cancels.write().await;
                            map.remove(&id);
                            return;
                        }
                        Err(e) => {
                            send_event(
                                &tx,
                                &Event::Error {
                                    id,
                                    message: format!("fuzzy match failed: {e}"),
                                },
                            )
                            .await;
                            let mut map = cancels.write().await;
                            map.remove(&id);
                            return;
                        }
                    };
                    let capped = total > items.len();
                    send_event(
                        &tx,
                        &Event::FilesResult {
                            id,
                            items,
                            done: true,
                            total,
                            capped,
                            elapsed_ms: started.elapsed().as_millis(),
                        },
                    )
                    .await;

                    let mut map = cancels.write().await;
                    map.remove(&id);
                });
            }
            Request::Grep {
                id,
                root,
                pattern,
                regex,
                ignore_case,
                max,
                hidden,
                no_ignore,
            } => {
                let tx = out_tx.clone();
                let cancels = cancels.clone();
                let token = CancellationToken::new();
                {
                    let mut map = cancels.write().await;
                    map.insert(id, token.clone());
                }

                tokio::spawn(async move {
                    let started = Instant::now();
                    let token_clone = token.clone();
                    let max = max.min(5_000);
                    let result = tokio::task::spawn_blocking(move || {
                        handle_grep_sync(
                            &root,
                            &pattern,
                            GrepOptions {
                                is_regex: regex,
                                ignore_case,
                                max,
                                hidden,
                                no_ignore,
                            },
                            &token_clone,
                        )
                    })
                    .await;

                    match result {
                        Ok(Ok((items, capped))) => {
                            let total = items.len();
                            send_event(
                                &tx,
                                &Event::GrepResult {
                                    id,
                                    items,
                                    done: true,
                                    total,
                                    capped,
                                    elapsed_ms: started.elapsed().as_millis(),
                                },
                            )
                            .await;
                        }
                        Ok(Err(msg)) => {
                            send_event(&tx, &Event::Error { id, message: msg }).await;
                        }
                        Err(e) => {
                            send_event(
                                &tx,
                                &Event::Error {
                                    id,
                                    message: format!("task failed: {e}"),
                                },
                            )
                            .await;
                        }
                    }

                    let mut map = cancels.write().await;
                    map.remove(&id);
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, time::SystemTime};

    fn temp_project() -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("simplefinder-test-{unique}"));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn fuzzy_filter_is_ranked_and_deterministic() {
        let files = vec![
            "src/simple_finder.rs".to_string(),
            "docs/finder.md".to_string(),
            "src/other.rs".to_string(),
        ];
        let token = CancellationToken::new();
        let (items, total) = fuzzy_filter(&files, "finder", 10, &token).unwrap();

        assert_eq!(total, 2);
        assert_eq!(items.len(), 2);
        assert!(items[0].score >= items[1].score);
        assert!(items.iter().all(|item| item.path.contains("finder")));
    }

    #[test]
    fn fuzzy_filter_reports_total_before_truncation() {
        let files = vec!["a.rs".into(), "ab.rs".into(), "abc.rs".into()];
        let (items, total) = fuzzy_filter(&files, "a", 1, &CancellationToken::new()).unwrap();

        assert_eq!(items.len(), 1);
        assert_eq!(total, 3);
    }

    #[test]
    fn grep_literal_and_case_options_work() {
        let root = temp_project();
        fs::write(root.join("sample.txt"), "alpha [one]\nALPHA two\n").unwrap();

        let (literal, _) = handle_grep_sync(
            root.to_str().unwrap(),
            "[one]",
            GrepOptions {
                is_regex: false,
                ignore_case: false,
                max: 20,
                hidden: false,
                no_ignore: false,
            },
            &CancellationToken::new(),
        )
        .unwrap();
        let (folded, _) = handle_grep_sync(
            root.to_str().unwrap(),
            "alpha",
            GrepOptions {
                is_regex: false,
                ignore_case: true,
                max: 20,
                hidden: false,
                no_ignore: false,
            },
            &CancellationToken::new(),
        )
        .unwrap();

        assert_eq!(literal.len(), 1);
        assert_eq!(literal[0].col, 7);
        assert_eq!(folded.len(), 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_root_returns_a_useful_error() {
        let error = validate_root("/path/that/does/not/exist/simplefinder").unwrap_err();
        assert!(error.contains("cannot access root"));
    }
}
