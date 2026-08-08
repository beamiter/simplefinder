use grep_matcher::Matcher;
use grep_searcher::{BinaryDetection, SearcherBuilder, sinks::UTF8};
use ignore::{WalkBuilder, overrides::OverrideBuilder};
use nucleo_matcher::{
    Config, Matcher as NucleoMatcher, Utf32Str,
    pattern::{CaseMatching, Normalization, Pattern},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
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
        #[serde(default)]
        include_globs: Vec<String>,
        #[serde(default)]
        exclude_globs: Vec<String>,
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
        #[serde(default)]
        include_globs: Vec<String>,
        #[serde(default)]
        exclude_globs: Vec<String>,
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
const PROTOCOL_VERSION: u32 = 3;

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
        /// False when the scan ceiling stopped the walk, which makes `total` a
        /// lower bound.  The Vim side defaults it to true, so an older daemon
        /// — which reports `total == items.len()` and can only ever render
        /// `200+ results` — keeps its old, non-committal wording.
        total_exact: bool,
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
        ("path_globs", true),
    ])
}

#[derive(Debug, Serialize, Clone)]
struct FileItem {
    path: String,
    score: i64,
    /// Char indices into `path` matched by the query, for highlighting.
    indices: Vec<usize>,
}

/// The derived ordering is load-bearing, not incidental: the fields are laid
/// out so that `Ord` *is* the (path, lnum, col) result order, which lets a
/// bounded heap keep exactly the first `max` results a complete sort would
/// have produced.  Reordering these fields silently reorders the panel.
#[derive(Debug, Serialize, Clone, PartialEq, Eq, PartialOrd, Ord)]
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
    include_globs: &[String],
    exclude_globs: &[String],
    token: &CancellationToken,
) -> Result<Option<Arc<Vec<String>>>, String> {
    let root_path = validate_root(root)?;
    let cache_key = serde_json::to_string(&(
        root_path.to_string_lossy(),
        hidden,
        no_ignore,
        include_globs,
        exclude_globs,
    ))
    .map_err(|error| format!("could not build file-cache key: {error}"))?;
    let overrides = build_path_overrides(&root_path, include_globs, exclude_globs)?;

    // Check cache first (with TTL)
    {
        let c = cache.read().await;
        if let Some(entry) = c.get(&cache_key)
            && entry.created.elapsed().as_secs() < CACHE_TTL_SECS
        {
            return Ok(Some(Arc::clone(&entry.files)));
        }
    }

    // Walk in blocking thread to avoid stalling the async runtime
    let token_clone = token.clone();
    let files = tokio::task::spawn_blocking(move || {
        let mut builder = WalkBuilder::new(&root_path);
        builder
            .hidden(!hidden)
            .threads(num_cpus::get().min(8))
            .overrides(overrides);
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

const MAX_PATH_GLOBS: usize = 256;
const MAX_PATH_GLOB_BYTES: usize = 4096;

/// Build one native `ignore` override set for both file finding and grep.
/// Positive overrides are includes; a leading `!` turns a pattern into an
/// exclusion.  The Vim API keeps those in separate lists so a typo cannot
/// silently invert a filter.
fn build_path_overrides(
    root: &std::path::Path,
    include_globs: &[String],
    exclude_globs: &[String],
) -> Result<ignore::overrides::Override, String> {
    if include_globs.len() + exclude_globs.len() > MAX_PATH_GLOBS {
        return Err(format!("too many path globs (maximum {MAX_PATH_GLOBS})"));
    }

    let mut builder = OverrideBuilder::new(root);
    for (kind, patterns) in [("include", include_globs), ("exclude", exclude_globs)] {
        for pattern in patterns {
            if pattern.is_empty() {
                return Err(format!("{kind} glob must not be empty"));
            }
            if pattern.len() > MAX_PATH_GLOB_BYTES {
                return Err(format!("{kind} glob exceeds {MAX_PATH_GLOB_BYTES} bytes"));
            }
            if pattern.starts_with('!') {
                return Err(format!(
                    "{kind} glob {pattern:?} must not start with !; use the separate exclude list"
                ));
            }
            let override_pattern = if kind == "exclude" {
                format!("!{pattern}")
            } else {
                pattern.clone()
            };
            builder
                .add(&override_pattern)
                .map_err(|error| format!("invalid {kind} glob {pattern:?}: {error}"))?;
        }
    }
    builder
        .build()
        .map_err(|error| format!("could not build path globs: {error}"))
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

#[derive(Clone)]
struct GrepOptions {
    is_regex: bool,
    ignore_case: bool,
    max: usize,
    hidden: bool,
    no_ignore: bool,
    include_globs: Vec<String>,
    exclude_globs: Vec<String>,
}

/// What a grep walk found.
///
/// `total` counts every match the walk saw, not just the ones that fit into
/// `items`, so the panel can say `200/5312 results` instead of an
/// unfalsifiable `200+`.
struct GrepOutcome {
    items: Vec<GrepItem>,
    total: usize,
    /// False once the scan ceiling stopped the walk; `total` is then a lower
    /// bound and `items` is whatever the walk had reached, so callers must not
    /// present either as complete.
    total_exact: bool,
}

/// How many matches a single query may scan before the walk gives up counting.
///
/// Counting every match is what makes the reported total honest, but `.` as a
/// regex over a monorepo matches every line of every file, and a user who
/// asked for 200 results does not want to pay for a full read of the tree.
/// The ceiling scales with the request so a deliberately large `max` still
/// gets a proportionate scan, with a floor that keeps ordinary queries — which
/// are nowhere near it — exact and therefore fully deterministic.
const GREP_SCAN_CEILING_FACTOR: usize = 50;
const GREP_SCAN_CEILING_MIN: usize = 10_000;

fn handle_grep_sync(
    root: &str,
    pattern: &str,
    options: GrepOptions,
    token: &CancellationToken,
) -> Result<GrepOutcome, String> {
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
    let overrides =
        build_path_overrides(&root_path, &options.include_globs, &options.exclude_globs)?;
    // Worker threads used to append into a shared Vec in walk-completion
    // order, and the drain below truncated that unordered Vec *before*
    // sorting: the 200 results a user saw for a common term were a
    // scheduling-dependent subset that differed between two identical
    // queries, and <C-q> exported whichever one this run happened to
    // produce.  A bounded max-heap keeps exactly the `max` smallest items
    // under GrepItem's (path, lnum, col) ordering, which is the same set a
    // full sort-then-truncate would have produced, without ever holding more
    // than `max` items in memory.
    let best: Arc<std::sync::Mutex<std::collections::BinaryHeap<GrepItem>>> =
        Arc::new(std::sync::Mutex::new(std::collections::BinaryHeap::new()));
    let total = Arc::new(AtomicUsize::new(0));
    let ceiling_hit = Arc::new(AtomicBool::new(false));

    let mut builder = WalkBuilder::new(&root_path);
    builder
        .hidden(!options.hidden)
        .threads(num_cpus::get().min(8))
        .overrides(overrides);
    if options.no_ignore {
        builder
            .ignore(false)
            .git_ignore(false)
            .git_global(false)
            .git_exclude(false);
    }
    let walker = builder.build_parallel();
    let max_results = options.max.max(1);
    let ceiling = max_results
        .saturating_mul(GREP_SCAN_CEILING_FACTOR)
        .max(GREP_SCAN_CEILING_MIN);

    walker.run(|| {
        let matcher = matcher.clone();
        let root_path = root_path.to_path_buf();
        let best = Arc::clone(&best);
        let total = Arc::clone(&total);
        let ceiling_hit = Arc::clone(&ceiling_hit);
        let token = token.clone();
        let mut searcher = SearcherBuilder::new()
            .binary_detection(BinaryDetection::quit(b'\x00'))
            .build();

        Box::new(move |entry| {
            if token.is_cancelled() || ceiling_hit.load(Ordering::Relaxed) {
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

            let mut local_items: Vec<GrepItem> = Vec::new();
            let mut local_total: usize = 0;
            let _ = searcher.search_path(
                &matcher,
                &path,
                UTF8(|lnum, line| {
                    local_total += 1;
                    // Matches arrive in ascending line order within one file,
                    // so its first `max_results` are the only ones that can
                    // survive the global ordering; the rest are only counted.
                    // Reading on past that point is what makes `total` honest,
                    // and the file is open either way.
                    if local_items.len() < max_results {
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
                    }
                    // One pathological file must not outrun the global ceiling
                    // on its own, so bound this scan too.
                    Ok(!token.is_cancelled()
                        && local_total < ceiling
                        && !ceiling_hit.load(Ordering::Relaxed))
                }),
            );

            if local_total > 0 {
                let seen = total.fetch_add(local_total, Ordering::Relaxed) + local_total;
                if seen >= ceiling {
                    ceiling_hit.store(true, Ordering::Relaxed);
                }
            }
            if !local_items.is_empty() {
                let mut heap = best.lock().unwrap();
                for item in local_items {
                    heap.push(item);
                    if heap.len() > max_results {
                        // BinaryHeap is a max-heap, so this drops the item
                        // furthest down the (path, lnum, col) order.
                        heap.pop();
                    }
                }
            }

            ignore::WalkState::Continue
        })
    });

    let heap = std::mem::take(&mut *best.lock().unwrap());
    Ok(GrepOutcome {
        items: heap.into_sorted_vec(),
        total: total.load(Ordering::Relaxed),
        total_exact: !ceiling_hit.load(Ordering::Relaxed),
    })
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

const USAGE: &str = "\
Usage: simplefinder-daemon [OPTION]

With no arguments the daemon serves newline-delimited JSON requests on stdin
and writes replies to stdout.  That is how the Vim plugin starts it; there is
nothing useful to do with it interactively.

Options:
  -V, --version    print the version and exit
  -h, --help       print this help and exit
      --self-test  check that the handshake reply serialises and that it
                   announces this build's protocol version, then exit
";

/// Cheap coherence check for the installer.
///
/// The request loop lives inside `main` and cannot be driven in-process
/// without restructuring it, so this stops short of a full round trip: it
/// builds the handshake reply the Vim side gates its features on and confirms
/// it serialises to the announced protocol version.  That catches a mismatched
/// or half-linked binary, which is what the installer is actually asking about.
fn self_test() -> Result<(), String> {
    let pong = Event::Pong {
        id: 0,
        protocol_version: PROTOCOL_VERSION,
        version: env!("CARGO_PKG_VERSION"),
        capabilities: capabilities(),
    };
    let encoded =
        serde_json::to_string(&pong).map_err(|error| format!("handshake reply: {error}"))?;
    let parsed: serde_json::Value =
        serde_json::from_str(&encoded).map_err(|error| format!("handshake reply: {error}"))?;

    match parsed.get("protocol_version").and_then(|v| v.as_u64()) {
        Some(version) if version == u64::from(PROTOCOL_VERSION) => Ok(()),
        Some(version) => Err(format!(
            "handshake announced protocol {version}, this build is {PROTOCOL_VERSION}"
        )),
        None => Err(format!("handshake carried no protocol version: {encoded}")),
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => match serve().await {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("simplefinder-daemon: {error}");
                std::process::ExitCode::FAILURE
            }
        },
        Some("--version" | "-V") => {
            println!("simplefinder-daemon {}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        Some("--help" | "-h") => {
            println!(
                "simplefinder-daemon {}\n\n{USAGE}",
                env!("CARGO_PKG_VERSION")
            );
            std::process::ExitCode::SUCCESS
        }
        Some("--self-test") => match self_test() {
            Ok(()) => {
                println!("ok");
                std::process::ExitCode::SUCCESS
            }
            Err(message) => {
                eprintln!("self-test failed: {message}");
                std::process::ExitCode::FAILURE
            }
        },
        Some(other) => {
            eprintln!("unknown argument: {other}\n\n{USAGE}");
            std::process::ExitCode::from(2)
        }
    }
}

async fn serve() -> std::io::Result<()> {
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
                include_globs,
                exclude_globs,
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
                    let files = match get_or_walk_files(
                        &cache,
                        &root,
                        hidden,
                        no_ignore,
                        &include_globs,
                        &exclude_globs,
                        &token,
                    )
                    .await
                    {
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
                include_globs,
                exclude_globs,
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
                                include_globs,
                                exclude_globs,
                            },
                            &token_clone,
                        )
                    })
                    .await;

                    match result {
                        Ok(Ok(outcome)) => {
                            let capped = outcome.total > outcome.items.len();
                            send_event(
                                &tx,
                                &Event::GrepResult {
                                    id,
                                    items: outcome.items,
                                    done: true,
                                    total: outcome.total,
                                    capped,
                                    total_exact: outcome.total_exact,
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

        let literal = handle_grep_sync(
            root.to_str().unwrap(),
            "[one]",
            GrepOptions {
                is_regex: false,
                ignore_case: false,
                max: 20,
                hidden: false,
                no_ignore: false,
                include_globs: Vec::new(),
                exclude_globs: Vec::new(),
            },
            &CancellationToken::new(),
        )
        .unwrap();
        let folded = handle_grep_sync(
            root.to_str().unwrap(),
            "alpha",
            GrepOptions {
                is_regex: false,
                ignore_case: true,
                max: 20,
                hidden: false,
                no_ignore: false,
                include_globs: Vec::new(),
                exclude_globs: Vec::new(),
            },
            &CancellationToken::new(),
        )
        .unwrap();

        assert_eq!(literal.items.len(), 1);
        assert_eq!(literal.items[0].col, 7);
        assert_eq!(literal.items[0].col_end, 12);
        assert_eq!(folded.items.len(), 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn grep_skips_binary_and_truncates_long_lines() {
        let root = temp_project();
        fs::write(root.join("bin.dat"), b"needle\x00binary").unwrap();
        let long = format!("{}needle", "x".repeat(600));
        fs::write(root.join("long.txt"), &long).unwrap();

        let items = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            GrepOptions {
                is_regex: false,
                ignore_case: false,
                max: 20,
                hidden: false,
                no_ignore: false,
                include_globs: Vec::new(),
                exclude_globs: Vec::new(),
            },
            &CancellationToken::new(),
        )
        .unwrap();

        assert_eq!(items.items.len(), 1);
        assert_eq!(items.items[0].path, "long.txt");
        assert!(items.items[0].text.len() <= MAX_LINE_BYTES + '…'.len_utf8());
        assert!(items.items[0].text.ends_with('…'));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_root_returns_a_useful_error() {
        let error = validate_root("/path/that/does/not/exist/simplefinder").unwrap_err();
        assert!(error.contains("cannot access root"));
    }

    /// A capped grep used to hand back whichever matches the walk threads
    /// happened to append first: results were accumulated in completion order
    /// and truncated *before* being sorted, so two identical queries returned
    /// two different subsets and `<C-q>` exported an arbitrary one of them.
    /// The bounded heap has to return the same prefix of the sorted result
    /// every time, and the count it reports has to be the real number of
    /// matches rather than the number that fit.
    #[test]
    fn a_capped_grep_is_deterministic_and_counts_every_match() {
        let root = temp_project();
        // Enough files, and enough matches per file, that the walk needs more
        // than one thread and more than one batch to finish.
        for file in 0..24 {
            let body: String = (0..8)
                .map(|line| format!("needle {file} {line}\n"))
                .collect();
            fs::write(root.join(format!("file{file:02}.txt")), body).unwrap();
        }

        let run = || {
            handle_grep_sync(
                root.to_str().unwrap(),
                "needle",
                GrepOptions {
                    is_regex: false,
                    ignore_case: false,
                    max: 20,
                    hidden: false,
                    no_ignore: false,
                    include_globs: Vec::new(),
                    exclude_globs: Vec::new(),
                },
                &CancellationToken::new(),
            )
            .unwrap()
        };

        let first = run();
        assert_eq!(first.items.len(), 20, "the cap is honoured");
        assert_eq!(
            first.total,
            24 * 8,
            "every match is counted, not just the kept ones"
        );
        assert!(first.total_exact);
        assert!(
            first.total > first.items.len(),
            "the fixture must actually exceed the cap"
        );

        // The kept results are the first `max` of the fully sorted result,
        // which is the only subset a user can reason about.
        let mut sorted = first.items.clone();
        sorted.sort();
        assert_eq!(
            sorted, first.items,
            "results come back in (path, lnum, col) order"
        );
        assert_eq!(first.items[0].path, "file00.txt");
        assert_eq!(first.items[0].lnum, 1);

        for _ in 0..8 {
            let again = run();
            assert_eq!(
                serde_json::to_string(&again.items).unwrap(),
                serde_json::to_string(&first.items).unwrap(),
                "two runs of the same capped query must be byte-identical"
            );
            assert_eq!(again.total, first.total);
        }

        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn path_globs_limit_file_walk_and_grep() {
        let root = temp_project();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::create_dir_all(root.join("docs")).unwrap();
        fs::write(root.join("src/keep.rs"), "fn needle() {}\n").unwrap();
        fs::write(root.join("src/skip.generated.rs"), "fn needle() {}\n").unwrap();
        fs::write(root.join("docs/readme.md"), "needle\n").unwrap();

        let include = vec!["*.rs".to_owned()];
        let exclude = vec!["*.generated.rs".to_owned()];
        let cache: FileCache = Arc::new(RwLock::new(HashMap::new()));
        let token = CancellationToken::new();
        let files = get_or_walk_files(
            &cache,
            root.to_str().unwrap(),
            false,
            false,
            &include,
            &exclude,
            &token,
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(files.as_ref(), &["src/keep.rs"]);

        // The cache key includes the complete filter snapshot. Reusing this
        // root with another include set must walk/cache a distinct path list.
        let markdown = get_or_walk_files(
            &cache,
            root.to_str().unwrap(),
            false,
            false,
            &["*.md".to_owned()],
            &[],
            &token,
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(markdown.as_ref(), &["docs/readme.md"]);
        assert_eq!(cache.read().await.len(), 2);

        let grepped = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            GrepOptions {
                is_regex: false,
                ignore_case: false,
                max: 20,
                hidden: false,
                no_ignore: false,
                include_globs: include,
                exclude_globs: exclude,
            },
            &token,
        )
        .unwrap();
        assert_eq!(grepped.total, 1);
        assert!(grepped.total_exact);
        assert_eq!(grepped.items.len(), 1);
        assert_eq!(grepped.items[0].path, "src/keep.rs");

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_or_inverted_path_globs_are_rejected() {
        let root = temp_project();
        let malformed = build_path_overrides(&root, &["[unclosed".to_owned()], &[])
            .expect_err("an invalid glob must not silently match the wrong files");
        assert!(malformed.contains("invalid include glob"));

        let inverted = build_path_overrides(&root, &["!*.rs".to_owned()], &[])
            .expect_err("the separate include/exclude API must not be inverted with !");
        assert!(inverted.contains("must not start with !"));
        fs::remove_dir_all(root).unwrap();
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
