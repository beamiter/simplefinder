use grep_matcher::Matcher;
use grep_searcher::{BinaryDetection, SearcherBuilder, sinks::UTF8};
use ignore::WalkBuilder;
use nucleo_matcher::{
    Config, Matcher as NucleoMatcher, Utf32Str,
    pattern::{CaseMatching, Normalization, Pattern},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::Arc,
    time::Instant,
};
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
    /// Capability handshake.  The Vim side sends this once per daemon start and
    /// gates optional features on the answer, so an older daemon paired with a
    /// newer plugin degrades instead of misbehaving.
    #[serde(rename = "ping")]
    Ping {
        #[serde(default)]
        id: u64,
    },
}

fn default_max() -> usize {
    200
}

/// Bumped whenever the wire format changes in a way the Vim side must know
/// about.  v1 was the implicit, un-negotiated format.
const PROTOCOL_VERSION: u32 = 2;

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
    #[serde(rename = "pong")]
    Pong {
        id: u64,
        protocol_version: u32,
        version: &'static str,
        capabilities: BTreeMap<&'static str, bool>,
    },
}

fn capabilities() -> BTreeMap<&'static str, bool> {
    BTreeMap::from([
        ("files", true),
        ("grep", true),
        ("cancel", true),
        ("match_indices", true),
    ])
}

#[derive(Debug, Serialize, Clone)]
struct FileItem {
    path: String,
    score: i64,
    /// Char indices into `path` matched by the query, for highlighting.
    indices: Vec<usize>,
}

#[derive(Debug, Serialize, Clone)]
struct GrepItem {
    path: String,
    lnum: usize,
    col: usize,
    /// 1-based exclusive byte offset of the match end within `text`.
    col_end: usize,
    text: String,
}

/// Cap stored line length so minified/generated files don't flood the UI.
const MAX_LINE_BYTES: usize = 512;

fn truncate_line(line: &str) -> String {
    let trimmed = line.trim_end();
    if trimmed.len() <= MAX_LINE_BYTES {
        return trimmed.to_string();
    }
    let mut end = MAX_LINE_BYTES;
    while end > 0 && !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &trimmed[..end])
}

// ─────────────────── File cache ───────────────────

const CACHE_TTL_SECS: u64 = 30;

/// Upper bound on how many distinct roots stay cached.  The daemon outlives
/// every search, and each entry retains the full path list of a project; left
/// alone the map grew for the whole session, since the TTL only decided
/// whether an entry was *fresh*, never whether it was still worth keeping.
/// Four keys exist per root (hidden × no_ignore), so this holds a handful of
/// projects with their toggles.
const CACHE_MAX_ROOTS: usize = 16;

struct CacheEntry {
    files: Arc<Vec<String>>,
    created: Instant,
}

type FileCache = Arc<RwLock<HashMap<String, CacheEntry>>>;

/// Drop entries that can no longer be served from cache, then enforce the
/// size bound by evicting the oldest.  Called while inserting, so the write
/// lock is already held and the cost is paid on a path that just walked a
/// whole directory tree.
fn prune_cache(cache: &mut HashMap<String, CacheEntry>) {
    cache.retain(|_, entry| entry.created.elapsed().as_secs() < CACHE_TTL_SECS);
    while cache.len() > CACHE_MAX_ROOTS {
        let Some(oldest) = cache
            .iter()
            .min_by_key(|(_, entry)| entry.created)
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        cache.remove(&oldest);
    }
}

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
        builder.hidden(!hidden).threads(num_cpus::get().min(8));
        if no_ignore {
            builder
                .ignore(false)
                .git_ignore(false)
                .git_global(false)
                .git_exclude(false);
        }

        let (file_tx, file_rx) = std::sync::mpsc::channel::<String>();
        builder.build_parallel().run(|| {
            let file_tx = file_tx.clone();
            let root_path = root_path.clone();
            let token = token_clone.clone();
            Box::new(move |entry| {
                if token.is_cancelled() {
                    return ignore::WalkState::Quit;
                }
                let entry = match entry {
                    Ok(e) => e,
                    Err(_) => return ignore::WalkState::Continue,
                };
                if !entry.file_type().is_some_and(|ft| ft.is_file()) {
                    return ignore::WalkState::Continue;
                }
                if let Ok(rel) = entry.path().strip_prefix(&root_path) {
                    let _ = file_tx.send(rel.to_string_lossy().into_owned());
                }
                ignore::WalkState::Continue
            })
        });
        drop(file_tx);

        if token_clone.is_cancelled() {
            return None;
        }
        let mut files: Vec<String> = file_rx.into_iter().collect();
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
        prune_cache(&mut c);
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
                indices: Vec::new(),
            })
            .collect();
        return Some((items, files.len()));
    }

    let mut matcher = NucleoMatcher::new(Config::DEFAULT);
    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);

    // Score as (score, index) pairs: no path is cloned until it survives
    // truncation, and the Utf32 scratch buffer is reused across candidates.
    let mut buf = Vec::new();
    let mut scored: Vec<(i64, usize)> = Vec::new();
    for (index, p) in files.iter().enumerate() {
        if index % 1024 == 0 && token.is_cancelled() {
            return None;
        }
        let haystack = Utf32Str::new(p, &mut buf);
        if let Some(score) = pattern.score(haystack, &mut matcher) {
            scored.push((score as i64, index));
        }
    }

    let total = scored.len();
    scored.sort_unstable_by(|a, b| b.0.cmp(&a.0).then_with(|| files[a.1].cmp(&files[b.1])));
    scored.truncate(max);

    // Only the surviving page is materialized and needs highlight positions.
    let mut idx_buf: Vec<u32> = Vec::new();
    let mut items: Vec<FileItem> = Vec::with_capacity(scored.len());
    for (score, index) in scored {
        let path = &files[index];
        idx_buf.clear();
        let haystack = Utf32Str::new(path, &mut buf);
        let indices = if pattern
            .indices(haystack, &mut matcher, &mut idx_buf)
            .is_some()
        {
            idx_buf.sort_unstable();
            idx_buf.dedup();
            idx_buf.iter().map(|&i| i as usize).collect()
        } else {
            Vec::new()
        };
        items.push(FileItem {
            path: path.clone(),
            score,
            indices,
        });
    }
    Some((items, total))
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
        let mut searcher = SearcherBuilder::new()
            .binary_detection(BinaryDetection::quit(b'\x00'))
            .build();

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
                    let (col, col_end) = matcher
                        .find(line.as_bytes())
                        .ok()
                        .flatten()
                        .map(|m| (m.start() + 1, m.end() + 1))
                        .unwrap_or((1, 1));
                    local_items.push(GrepItem {
                        path: rel.clone(),
                        lnum: lnum as usize,
                        col,
                        col_end,
                        text: truncate_line(line),
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
            Request::Ping { id } => {
                send_event(
                    &out_tx,
                    &Event::Pong {
                        id,
                        protocol_version: PROTOCOL_VERSION,
                        version: env!("CARGO_PKG_VERSION"),
                        capabilities: capabilities(),
                    },
                )
                .await;
            }
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
        // Highlight indices point at the matched chars in each path.
        for item in &items {
            assert!(!item.indices.is_empty());
            let chars: Vec<char> = item.path.chars().collect();
            let matched: String = item.indices.iter().map(|&i| chars[i]).collect();
            assert_eq!(matched.to_lowercase(), "finder");
        }
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
        assert_eq!(literal[0].col_end, 12);
        assert_eq!(folded.len(), 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn grep_skips_binary_and_truncates_long_lines() {
        let root = temp_project();
        fs::write(root.join("bin.dat"), b"needle\x00binary").unwrap();
        let long = format!("{}needle", "x".repeat(600));
        fs::write(root.join("long.txt"), &long).unwrap();

        let (items, _) = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
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

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].path, "long.txt");
        assert!(items[0].text.len() <= MAX_LINE_BYTES + '…'.len_utf8());
        assert!(items[0].text.ends_with('…'));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_root_returns_a_useful_error() {
        let error = validate_root("/path/that/does/not/exist/simplefinder").unwrap_err();
        assert!(error.contains("cannot access root"));
    }

    use std::time::Duration;

    fn cache_entry(age: Duration) -> CacheEntry {
        CacheEntry {
            files: Arc::new(Vec::new()),
            created: Instant::now() - age,
        }
    }

    #[test]
    fn stale_cache_entries_are_dropped() {
        // The TTL used to decide only whether an entry could be *served*;
        // nothing ever removed it, so the daemon retained the full path list
        // of every project searched for the lifetime of the session.
        let mut cache = HashMap::new();
        cache.insert("fresh".to_string(), cache_entry(Duration::from_secs(0)));
        cache.insert(
            "stale".to_string(),
            cache_entry(Duration::from_secs(CACHE_TTL_SECS + 1)),
        );

        prune_cache(&mut cache);

        assert!(cache.contains_key("fresh"));
        assert!(
            !cache.contains_key("stale"),
            "an expired entry must be evicted"
        );
    }

    #[test]
    fn the_cache_is_bounded_and_evicts_the_oldest() {
        let mut cache = HashMap::new();
        // All fresh, so only the size bound can evict. Ages are staggered so
        // "oldest" is well defined.
        for i in 0..(CACHE_MAX_ROOTS + 4) {
            cache.insert(
                format!("root{i}"),
                cache_entry(Duration::from_millis(i as u64)),
            );
        }

        prune_cache(&mut cache);

        assert_eq!(cache.len(), CACHE_MAX_ROOTS);
        // The four highest indices are the oldest, so they are the ones gone.
        for i in (CACHE_MAX_ROOTS)..(CACHE_MAX_ROOTS + 4) {
            assert!(
                !cache.contains_key(&format!("root{i}")),
                "root{i} should have been evicted"
            );
        }
        assert!(cache.contains_key("root0"), "the newest entry must survive");
    }
}
