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
    time::{Duration, Instant},
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
        /// Worker threads for the walk and the scoring; 0 means "one per
        /// core".  An older daemon ignores the field, and an older plugin
        /// omits it, so both directions land on the default.
        #[serde(default)]
        threads: usize,
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
        /// Opt in to partial `done: false` batches.  The plugin sets it only
        /// after the handshake advertises `stream`, so an older plugin paired
        /// with this daemon keeps getting exactly one reply per request.
        #[serde(default)]
        stream: bool,
        /// Opt in to sharing the file finder's list of the tree instead of
        /// walking it again, and to publishing this grep's own walk into it.
        /// Off by default so an older plugin — which cannot know the list is
        /// at most CACHE_TTL_SECS old — keeps walking for every request.
        #[serde(default)]
        file_cache: bool,
        #[serde(default)]
        threads: usize,
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

/// How many worker threads a request may use.
///
/// The walk and the scoring were both pinned at `num_cpus().min(8)`: a
/// deliberate cap when eight cores was a big machine, and three quarters of a
/// 32-core box left idle now.  0 (the default) means one per core; an explicit
/// value is clamped to something a stray configuration cannot turn into
/// thousands of threads.
fn worker_threads(requested: usize) -> usize {
    const MAX_THREADS: usize = 64;
    if requested == 0 {
        num_cpus::get().clamp(1, MAX_THREADS)
    } else {
        requested.clamp(1, MAX_THREADS)
    }
}

/// Bumped whenever the wire format changes in a way the Vim side must know
/// about.  v1 was the implicit, un-negotiated format.  v4 added streamed grep
/// batches and the `total_exact` field on `grep_result`.
const PROTOCOL_VERSION: u32 = 4;

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
        ("stream", true),
        ("grep_cache", true),
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

/// Everything that decides which files a walk yields, and how many threads
/// yield them.  Grouped because every one of them belongs in the cache key:
/// two walks that disagree on any of the first four are not the same list.
struct WalkOptions<'a> {
    hidden: bool,
    no_ignore: bool,
    include_globs: &'a [String],
    exclude_globs: &'a [String],
    threads: usize,
}

/// The cache key for one set of walk options.
///
/// Grep now reads and writes the same cache as the file finder, so the key has
/// to be derived in exactly one place: two callers that disagreed by a field
/// would share an entry that does not describe the same tree.
fn walk_cache_key(
    root_path: &std::path::Path,
    options: &WalkOptions<'_>,
) -> Result<String, String> {
    serde_json::to_string(&(
        root_path.to_string_lossy(),
        options.hidden,
        options.no_ignore,
        options.include_globs,
        options.exclude_globs,
    ))
    .map_err(|error| format!("could not build file-cache key: {error}"))
}

/// The cached file list for these walk options, if a fresh one exists.
///
/// Never walks.  A caller that misses here does what it did unconditionally
/// before — walk — so a cold cache costs nothing but the lookup.
async fn cached_files(
    cache: &FileCache,
    root: &str,
    options: &WalkOptions<'_>,
) -> Option<Arc<Vec<String>>> {
    let root_path = validate_root(root).ok()?;
    let key = walk_cache_key(&root_path, options).ok()?;
    let map = cache.read().await;
    let entry = map.get(&key)?;
    (entry.created.elapsed().as_secs() < CACHE_TTL_SECS).then(|| Arc::clone(&entry.files))
}

/// Publish a file list produced outside `get_or_walk_files` — a grep walk —
/// so the next request can skip its own walk.  The caller must have walked the
/// whole tree with these options; a partial list here is invisible corruption.
async fn store_files(cache: &FileCache, root: &str, options: &WalkOptions<'_>, files: Vec<String>) {
    // Both failures mean the root vanished or is unserialisable, which the
    // grep that produced this list has already reported; there is nothing to
    // cache and nothing further to say.
    let Ok(root_path) = validate_root(root) else {
        return;
    };
    let Ok(key) = walk_cache_key(&root_path, options) else {
        return;
    };
    let mut map = cache.write().await;
    map.insert(
        key,
        CacheEntry {
            files: Arc::new(files),
            created: Instant::now(),
        },
    );
    prune_cache(&mut map);
}

async fn get_or_walk_files(
    cache: &FileCache,
    root: &str,
    options: &WalkOptions<'_>,
    token: &CancellationToken,
) -> Result<Option<Arc<Vec<String>>>, String> {
    let WalkOptions {
        hidden,
        no_ignore,
        include_globs,
        exclude_globs,
        threads,
    } = *options;
    let root_path = validate_root(root)?;
    let cache_key = walk_cache_key(&root_path, options)?;
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
            .threads(worker_threads(threads))
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

/// Fewest candidates worth handing to a thread of its own.  Scoring a short
/// path is a few hundred nanoseconds, so splitting a small list costs more in
/// thread setup than it saves.
const FUZZY_CHUNK_MIN: usize = 2_000;

/// Score one slice of the candidate list.  `None` means the search was
/// cancelled — a superseded keystroke — and nothing downstream should run.
fn score_range(
    files: &[String],
    range: std::ops::Range<usize>,
    pattern: &Pattern,
    token: &CancellationToken,
) -> Option<Vec<(i64, usize)>> {
    let mut matcher = NucleoMatcher::new(Config::DEFAULT);
    // Score as (score, index) pairs: no path is cloned until it survives
    // truncation, and the Utf32 scratch buffer is reused across candidates.
    let mut buf = Vec::new();
    let mut scored: Vec<(i64, usize)> = Vec::new();
    for index in range {
        if index % 1024 == 0 && token.is_cancelled() {
            return None;
        }
        let haystack = Utf32Str::new(&files[index], &mut buf);
        if let Some(score) = pattern.score(haystack, &mut matcher) {
            scored.push((score as i64, index));
        }
    }
    Some(scored)
}

fn fuzzy_filter(
    files: &[String],
    query: &str,
    max: usize,
    threads: usize,
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

    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);

    // Every keystroke rescores the whole file list, and on a 100k-file repo
    // that was one core doing all of it while the rest of the machine waited.
    // Scoring is embarrassingly parallel — each candidate is independent — so
    // the list is split, scored per thread with a matcher of its own, and the
    // partial results merged before the single sort that decides the order.
    // The sort breaks ties by path, so the merged order does not depend on
    // which thread finished first.
    let workers = worker_threads(threads).min(files.len().div_ceil(FUZZY_CHUNK_MIN).max(1));
    let mut scored: Vec<(i64, usize)> = if workers <= 1 {
        score_range(files, 0..files.len(), &pattern, token)?
    } else {
        let chunk = files.len().div_ceil(workers);
        std::thread::scope(|scope| {
            let handles: Vec<_> = (0..files.len())
                .step_by(chunk)
                .map(|start| {
                    let end = (start + chunk).min(files.len());
                    let pattern = &pattern;
                    scope.spawn(move || score_range(files, start..end, pattern, token))
                })
                .collect();
            let mut merged: Vec<(i64, usize)> = Vec::new();
            for handle in handles {
                // A panicking scorer is a bug, not a result: fail the search
                // rather than quietly return a partial ranking.
                merged.extend(handle.join().ok()??);
            }
            Some(merged)
        })?
    };

    let total = scored.len();
    scored.sort_unstable_by(|a, b| b.0.cmp(&a.0).then_with(|| files[a.1].cmp(&files[b.1])));
    scored.truncate(max);

    // Only the surviving page is materialized and needs highlight positions.
    let mut matcher = NucleoMatcher::new(Config::DEFAULT);
    let mut buf = Vec::new();
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
    /// Whether the caller wants this walk's file list back, to share with the
    /// file finder's cache.  False is the opt-out (`g:simplefinder_grep_cache
    /// = 0`, and every plugin too old to send the field), and it has to make
    /// the walk *cheaper*: nothing consumes the list on that path, so building
    /// one is pure overhead the option exists to avoid.
    file_cache: bool,
    /// 0 means one worker per core; see worker_threads().
    threads: usize,
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
    /// Every file the walk visited, sorted, when — and only when — the walk ran
    /// to completion.  A grep that had to walk anyway has produced exactly the
    /// list `get_or_walk_files` would have produced, so handing it back lets
    /// the caller warm the shared cache and spare the *next* keystroke its
    /// walk.  `None` after a cached scan (there was no walk) and after a walk
    /// that stopped early (the list would be a partial tree, which must never
    /// be cached as if it were whole).
    walked: Option<Vec<String>>,
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

/// Shortest gap between two streamed repaints.  The walk finds matches far
/// faster than a human can read them, and every batch costs Vim a full panel
/// render, so batching is what makes streaming cheaper than not streaming.
const STREAM_INTERVAL: Duration = Duration::from_millis(80);

/// Where a streaming grep sends a partial result: `(items, total, total_exact)`.
///
/// Every batch is a *snapshot* of the best results so far, never an append.
/// The bounded heap can promote a match found late into the middle of the
/// order, so appending would paint rows in walk order and then reshuffle them
/// under the user at the end; a snapshot only ever refines.  That is also why
/// dropping a batch is harmless — the next one supersedes it — which lets the
/// sink stay non-blocking.
type GrepSink = Arc<dyn Fn(Vec<GrepItem>, usize, bool) + Send + Sync>;

/// One grep in progress: the shared best-of set, the counters, and the
/// per-file work itself.
///
/// A grep can get its candidate files two ways — by walking the tree, or by
/// reading the list a recent walk already produced — and what happens *inside*
/// each file is identical either way.  Keeping that half here means the two
/// strategies cannot drift apart on ordering, on the scan ceiling, or on when
/// a streamed batch goes out.
struct GrepScan {
    /// Cloned per worker: `grep_searcher` wants an owned matcher and a
    /// `Searcher` of its own per thread, and cloning a compiled regex is far
    /// cheaper than compiling it again.
    matcher: grep_regex::RegexMatcher,
    /// Worker threads used to append into a shared Vec in walk-completion
    /// order, and the drain truncated that unordered Vec *before* sorting: the
    /// 200 results a user saw for a common term were a scheduling-dependent
    /// subset that differed between two identical queries, and `<C-q>`
    /// exported whichever one that run happened to produce.  A bounded
    /// max-heap keeps exactly the `max` smallest items under `GrepItem`'s
    /// (path, lnum, col) ordering — the same set a full sort-then-truncate
    /// would have produced — without ever holding more than `max` items.
    best: std::sync::Mutex<std::collections::BinaryHeap<GrepItem>>,
    total: AtomicUsize,
    ceiling_hit: AtomicBool,
    last_flush: std::sync::Mutex<Instant>,
    stream: Option<GrepSink>,
    max_results: usize,
    ceiling: usize,
}

impl GrepScan {
    fn new(
        matcher: grep_regex::RegexMatcher,
        max_results: usize,
        ceiling: usize,
        stream: Option<GrepSink>,
    ) -> Self {
        GrepScan {
            matcher,
            best: std::sync::Mutex::new(std::collections::BinaryHeap::new()),
            total: AtomicUsize::new(0),
            ceiling_hit: AtomicBool::new(false),
            // Backdated so the very first file with matches paints
            // immediately; the point of streaming is that a cold scan over a
            // monorepo shows something in milliseconds rather than after the
            // last file is read.
            last_flush: std::sync::Mutex::new(
                Instant::now()
                    .checked_sub(STREAM_INTERVAL)
                    .unwrap_or_else(Instant::now),
            ),
            stream,
            max_results,
            ceiling,
        }
    }

    /// True while the scan should keep going.
    fn running(&self, token: &CancellationToken) -> bool {
        !token.is_cancelled() && !self.ceiling_hit.load(Ordering::Relaxed)
    }

    fn matcher_for_worker(&self) -> grep_regex::RegexMatcher {
        self.matcher.clone()
    }

    /// Search one file and fold its matches into the best-of set.
    ///
    /// `rel` is the path as the panel will show it — relative to the search
    /// root — which is also the first key of the result ordering, so it has to
    /// be derived the same way whether it came from a walk or from the cache.
    fn visit(
        &self,
        searcher: &mut grep_searcher::Searcher,
        matcher: &grep_regex::RegexMatcher,
        path: &std::path::Path,
        rel: &str,
        token: &CancellationToken,
    ) {
        let mut local_items: Vec<GrepItem> = Vec::new();
        let mut local_total: usize = 0;
        let _ = searcher.search_path(
            matcher,
            path,
            UTF8(|lnum, line| {
                local_total += 1;
                // Matches arrive in ascending line order within one file, so
                // its first `max_results` are the only ones that can survive
                // the global ordering; the rest are only counted.  Reading on
                // past that point is what makes `total` honest, and the file
                // is open either way.
                if local_items.len() < self.max_results {
                    let (col, col_end) = matcher
                        .find(line.as_bytes())
                        .ok()
                        .flatten()
                        .map(|m| (m.start() + 1, m.end() + 1))
                        .unwrap_or((1, 1));
                    local_items.push(GrepItem {
                        path: rel.to_string(),
                        lnum: lnum as usize,
                        col,
                        col_end,
                        text: truncate_line(line),
                    });
                }
                // One pathological file must not outrun the global ceiling on
                // its own, so bound this scan too.
                Ok(local_total < self.ceiling && self.running(token))
            }),
        );

        if local_total > 0 {
            let seen = self.total.fetch_add(local_total, Ordering::Relaxed) + local_total;
            if seen >= self.ceiling {
                self.ceiling_hit.store(true, Ordering::Relaxed);
            }
        }
        if local_items.is_empty() {
            return;
        }

        {
            let mut heap = self.best.lock().unwrap();
            for item in local_items {
                heap.push(item);
                if heap.len() > self.max_results {
                    // BinaryHeap is a max-heap, so this drops the item
                    // furthest down the (path, lnum, col) order.
                    heap.pop();
                }
            }
        }

        // Repaint at most every STREAM_INTERVAL.  `last_flush` is taken before
        // `best` here and never the other way round, so the two locks cannot
        // deadlock against each other.
        let Some(sink) = &self.stream else {
            return;
        };
        let snapshot = {
            let mut last = self.last_flush.lock().unwrap();
            if last.elapsed() < STREAM_INTERVAL {
                None
            } else {
                *last = Instant::now();
                Some(self.best.lock().unwrap().clone().into_sorted_vec())
            }
        };
        if let Some(items) = snapshot {
            sink(
                items,
                self.total.load(Ordering::Relaxed),
                !self.ceiling_hit.load(Ordering::Relaxed),
            );
        }
    }

    /// Drain the best-of set into the reply.  `walked` is the caller's to fill
    /// in: only it knows whether this scan walked anything.
    fn finish(&self) -> GrepOutcome {
        let heap = std::mem::take(&mut *self.best.lock().unwrap());
        GrepOutcome {
            items: heap.into_sorted_vec(),
            total: self.total.load(Ordering::Relaxed),
            total_exact: !self.ceiling_hit.load(Ordering::Relaxed),
            walked: None,
        }
    }
}

/// Grep by walking the tree, returning every file the walk saw.
///
/// The returned list is `None` unless the caller asked for it *and* the walk
/// ran to completion: a scan that a cancelled keystroke or the ceiling cut
/// short has seen only part of the tree, and caching that as the project's
/// file list would make every later search blind to the rest of it.
fn grep_by_walk(
    scan: &Arc<GrepScan>,
    root_path: &std::path::Path,
    options: &GrepOptions,
    token: &CancellationToken,
) -> Result<Option<Vec<String>>, String> {
    let overrides =
        build_path_overrides(root_path, &options.include_globs, &options.exclude_globs)?;
    let mut builder = WalkBuilder::new(root_path);
    builder
        .hidden(!options.hidden)
        .threads(worker_threads(options.threads))
        .overrides(overrides);
    if options.no_ignore {
        builder
            .ignore(false)
            .git_ignore(false)
            .git_global(false)
            .git_exclude(false);
    }

    // A channel rather than a shared Vec behind a mutex: this fires for every
    // file in the tree, including the great majority with no match at all,
    // which used to touch no lock whatsoever.
    //
    // And no channel at all when the caller did not ask for the list: with
    // `file_cache` off nobody reads it, so sending, buffering and sorting one
    // String per file in the tree would make the documented escape hatch
    // strictly more expensive than the behaviour it restores.
    let (file_tx, file_rx) = if options.file_cache {
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        (Some(tx), Some(rx))
    } else {
        (None, None)
    };
    builder.build_parallel().run(|| {
        let matcher = scan.matcher_for_worker();
        let scan = Arc::clone(scan);
        let root_path = root_path.to_path_buf();
        let file_tx = file_tx.clone();
        let token = token.clone();
        let mut searcher = new_searcher();

        Box::new(move |entry| {
            if !scan.running(&token) {
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
            scan.visit(&mut searcher, &matcher, &path, &rel, &token);
            if let Some(file_tx) = &file_tx {
                let _ = file_tx.send(rel);
            }
            ignore::WalkState::Continue
        })
    });
    drop(file_tx);

    let Some(file_rx) = file_rx else {
        return Ok(None);
    };
    let mut walked: Vec<String> = file_rx.into_iter().collect();
    if !scan.running(token) {
        return Ok(None);
    }
    // Sorted, because this is handed to the same cache the file finder reads
    // and that list is ordered.
    walked.sort();
    Ok(Some(walked))
}

/// Grep the files a recent walk already found.
///
/// Interactive grep sends one request per keystroke, and each of those used to
/// re-walk the whole tree — re-reading every .gitignore and stat-ing every
/// directory — before it could read a single file.  When the shared cache
/// still holds a list built with these exact walk options, the tree is already
/// known and only the reading is left.
fn grep_by_list(
    scan: &GrepScan,
    root_path: &std::path::Path,
    files: &[String],
    threads: usize,
    token: &CancellationToken,
) {
    let workers = worker_threads(threads).min(files.len()).max(1);
    let chunk = files.len().div_ceil(workers).max(1);
    std::thread::scope(|scope| {
        for part in files.chunks(chunk) {
            scope.spawn(move || {
                let matcher = scan.matcher_for_worker();
                let mut searcher = new_searcher();
                for rel in part {
                    if !scan.running(token) {
                        return;
                    }
                    scan.visit(&mut searcher, &matcher, &root_path.join(rel), rel, token);
                }
            });
        }
    });
}

fn new_searcher() -> grep_searcher::Searcher {
    SearcherBuilder::new()
        .binary_detection(BinaryDetection::quit(b'\x00'))
        .build()
}

fn handle_grep_sync(
    root: &str,
    pattern: &str,
    options: GrepOptions,
    cached: Option<Arc<Vec<String>>>,
    stream: Option<GrepSink>,
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
    let max_results = options.max.max(1);
    let ceiling = max_results
        .saturating_mul(GREP_SCAN_CEILING_FACTOR)
        .max(GREP_SCAN_CEILING_MIN);
    let scan = Arc::new(GrepScan::new(matcher, max_results, ceiling, stream));

    let walked = match cached {
        Some(files) => {
            grep_by_list(&scan, &root_path, &files, options.threads, token);
            None
        }
        None => grep_by_walk(&scan, &root_path, &options, token)?,
    };

    Ok(GrepOutcome {
        walked,
        ..scan.finish()
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
                threads,
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
                        &WalkOptions {
                            hidden,
                            no_ignore,
                            include_globs: &include_globs,
                            exclude_globs: &exclude_globs,
                            threads,
                        },
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
                        fuzzy_filter(&files, &query, max, threads, &token_clone)
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
                stream,
                file_cache: use_file_cache,
                threads,
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
                    let token_clone = token.clone();
                    let max = max.min(5_000);
                    // Partial batches are best-effort: each one supersedes the
                    // last, so `try_send` may drop one when Vim is behind
                    // without losing anything.  Only the final `done: true`
                    // reply below is sent with backpressure, because it is the
                    // one the panel is not allowed to miss.
                    let sink: Option<GrepSink> = stream.then(|| {
                        let tx = tx.clone();
                        Arc::new(
                            move |items: Vec<GrepItem>, total: usize, total_exact: bool| {
                                let event = Event::GrepResult {
                                    id,
                                    done: false,
                                    total,
                                    capped: total > items.len(),
                                    total_exact,
                                    elapsed_ms: started.elapsed().as_millis(),
                                    items,
                                };
                                if let Ok(line) = serde_json::to_string(&event) {
                                    let _ = tx.try_send(line);
                                }
                            },
                        ) as GrepSink
                    });
                    // Interactive grep sends one request per keystroke and each
                    // used to re-walk the tree before reading a single file.
                    // The walk options are the file finder's, so a warm entry
                    // here is the same list a `files` request would serve.
                    let walk_options = WalkOptions {
                        hidden,
                        no_ignore,
                        include_globs: &include_globs,
                        exclude_globs: &exclude_globs,
                        threads,
                    };
                    let cached = if use_file_cache {
                        cached_files(&cache, &root, &walk_options).await
                    } else {
                        None
                    };
                    let root_for_cache = root.clone();
                    let globs_for_cache = (include_globs.clone(), exclude_globs.clone());
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
                                file_cache: use_file_cache,
                                threads,
                            },
                            cached,
                            sink,
                            &token_clone,
                        )
                    })
                    .await;

                    match result {
                        Ok(Ok(mut outcome)) => {
                            // A grep that had to walk has produced exactly the
                            // list the file finder walks for, so publish it and
                            // spare the next keystroke its own walk.  `walked`
                            // is None unless this request asked for the shared
                            // cache and the walk ran to completion.
                            if let Some(walked) = outcome.walked.take() {
                                let (include_globs, exclude_globs) = globs_for_cache;
                                store_files(
                                    &cache,
                                    &root_for_cache,
                                    &WalkOptions {
                                        hidden,
                                        no_ignore,
                                        include_globs: &include_globs,
                                        exclude_globs: &exclude_globs,
                                        threads,
                                    },
                                    walked,
                                )
                                .await;
                            }
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

    /// Scoring is split across threads, so the merge has to reproduce exactly
    /// what one thread would have produced: same survivors, same order, same
    /// total, same highlight positions.  A chunk boundary in the wrong place,
    /// or a merge that lets thread completion order leak into the ranking,
    /// shows up here as a different list.
    #[test]
    fn parallel_scoring_ranks_exactly_as_one_thread_would() {
        // Comfortably more candidates than FUZZY_CHUNK_MIN, so the parallel
        // path actually splits, with scores that genuinely differ: the query
        // matches contiguously in some paths and scattered in others.
        let mut files: Vec<String> = (0..9_000)
            .map(|n| format!("crates/pkg{n:04}/src/needle_target.rs"))
            .collect();
        files.extend((0..3_000).map(|n| format!("vendor/n{n:04}/e/e/d/l/e/other.rs")));
        files.extend((0..2_000).map(|n| format!("docs/unrelated{n:04}.md")));
        files.sort();

        let token = CancellationToken::new();
        let (single, single_total) = fuzzy_filter(&files, "needle", 200, 1, &token).unwrap();
        for threads in [2, 4, 13] {
            let (many, total) = fuzzy_filter(&files, "needle", 200, threads, &token).unwrap();
            assert_eq!(total, single_total, "{threads} threads changed the total");
            assert_eq!(
                many.iter().map(|i| &i.path).collect::<Vec<_>>(),
                single.iter().map(|i| &i.path).collect::<Vec<_>>(),
                "{threads} threads changed the ranking"
            );
            assert_eq!(
                many.iter().map(|i| &i.indices).collect::<Vec<_>>(),
                single.iter().map(|i| &i.indices).collect::<Vec<_>>(),
                "{threads} threads changed the highlight positions"
            );
        }
        assert_eq!(single.len(), 200, "the cap still applies");
    }

    /// An explicit thread count is honoured, and a nonsensical one cannot turn
    /// into thousands of threads or none at all.
    #[test]
    fn worker_threads_are_clamped() {
        assert_eq!(worker_threads(1), 1);
        assert_eq!(worker_threads(7), 7);
        assert_eq!(worker_threads(usize::MAX), 64);
        assert!(worker_threads(0) >= 1);
    }

    #[test]
    fn fuzzy_filter_is_ranked_and_deterministic() {
        let files = vec![
            "src/simple_finder.rs".to_string(),
            "docs/finder.md".to_string(),
            "src/other.rs".to_string(),
        ];
        let token = CancellationToken::new();
        let (items, total) = fuzzy_filter(&files, "finder", 10, 0, &token).unwrap();

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
        let (items, total) = fuzzy_filter(&files, "a", 1, 0, &CancellationToken::new()).unwrap();

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
                file_cache: true,
                threads: 0,
            },
            None,
            None,
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
                file_cache: true,
                threads: 0,
            },
            None,
            None,
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
                file_cache: true,
                threads: 0,
            },
            None,
            None,
            &CancellationToken::new(),
        )
        .unwrap();

        assert_eq!(items.items.len(), 1);
        assert_eq!(items.items[0].path, "long.txt");
        assert!(items.items[0].text.len() <= MAX_LINE_BYTES + '…'.len_utf8());
        assert!(items.items[0].text.ends_with('…'));
        fs::remove_dir_all(root).unwrap();
    }

    /// The wire format carried a `done` field from the start and nothing ever
    /// set it to false: every request produced exactly one event, so on a cold
    /// walk the panel said `Searching…` until the last file had been read.
    /// A streaming grep has to hand back usable results before the walk ends,
    /// and each batch has to be a correctly ordered snapshot in its own right
    /// — otherwise the rows would reshuffle under the user when the final
    /// batch lands.
    #[test]
    fn a_streaming_grep_reports_before_the_walk_finishes() {
        let root = temp_project();
        for file in 0..24 {
            let body: String = (0..8)
                .map(|line| format!("needle {file} {line}\n"))
                .collect();
            fs::write(root.join(format!("file{file:02}.txt")), body).unwrap();
        }

        let batches: Arc<std::sync::Mutex<Vec<Vec<GrepItem>>>> =
            Arc::new(std::sync::Mutex::new(Vec::new()));
        let collector = Arc::clone(&batches);
        let sink: GrepSink = Arc::new(move |items, _total, _exact| {
            collector.lock().unwrap().push(items);
        });

        let outcome = handle_grep_sync(
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
                file_cache: true,
                threads: 0,
            },
            None,
            Some(sink),
            &CancellationToken::new(),
        )
        .unwrap();

        let batches = batches.lock().unwrap();
        assert!(
            !batches.is_empty(),
            "a streaming grep must report at least one partial batch"
        );
        for batch in batches.iter() {
            assert!(!batch.is_empty(), "an empty batch is not worth a repaint");
            assert!(batch.len() <= 20, "a partial batch still honours the cap");
            let mut sorted = batch.clone();
            sorted.sort();
            assert_eq!(
                &sorted, batch,
                "every batch is a correctly ordered snapshot"
            );
        }
        // A batch reports what the walk knew at the time, so a match found
        // later can sort in above it and displace it entirely — that is what
        // "refines" means, and why batches replace rather than accumulate.
        // What they may never contain is a row that is not a real match.
        let every_match: std::collections::BTreeSet<_> = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            GrepOptions {
                is_regex: false,
                ignore_case: false,
                max: 24 * 8,
                hidden: false,
                no_ignore: false,
                include_globs: Vec::new(),
                exclude_globs: Vec::new(),
                file_cache: true,
                threads: 0,
            },
            None,
            None,
            &CancellationToken::new(),
        )
        .unwrap()
        .items
        .into_iter()
        .collect();
        for batch in batches.iter() {
            for item in batch {
                assert!(every_match.contains(item), "{item:?} is not a real match");
            }
        }

        // At least one batch has to have been sent while results were still
        // incomplete; otherwise nothing was gained over the old single reply.
        assert!(
            batches.iter().any(|batch| batch != &outcome.items),
            "results must reach the panel before the walk finishes"
        );

        // Streaming must not change what the search actually found.
        assert_eq!(outcome.items.len(), 20);
        assert_eq!(outcome.total, 24 * 8);

        drop(batches);
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
                    file_cache: true,
                    threads: 0,
                },
                None,
                None,
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

    fn grep_options(max: usize) -> GrepOptions {
        GrepOptions {
            is_regex: false,
            ignore_case: false,
            max,
            hidden: false,
            no_ignore: false,
            include_globs: Vec::new(),
            exclude_globs: Vec::new(),
            file_cache: true,
            threads: 0,
        }
    }

    /// Interactive grep sends a request per keystroke, and each one used to
    /// re-walk the tree.  A grep that walks now hands its file list back so the
    /// next one can skip the walk — which is only sound if that list is
    /// *exactly* what the file finder would have cached itself.
    #[tokio::test]
    async fn a_walking_grep_publishes_the_list_the_file_finder_would_have() {
        let root = temp_project();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("src/one.txt"), "needle\n").unwrap();
        fs::write(root.join("src/two.txt"), "nothing\n").unwrap();
        fs::write(root.join("three.txt"), "needle\n").unwrap();

        let outcome = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            grep_options(20),
            None,
            None,
            &CancellationToken::new(),
        )
        .unwrap();

        let cache: FileCache = Arc::new(RwLock::new(HashMap::new()));
        let options = WalkOptions {
            hidden: false,
            no_ignore: false,
            include_globs: &[],
            exclude_globs: &[],
            threads: 0,
        };
        let walked = get_or_walk_files(
            &cache,
            root.to_str().unwrap(),
            &options,
            &CancellationToken::new(),
        )
        .await
        .unwrap()
        .unwrap();

        assert_eq!(
            outcome.walked.as_deref(),
            Some(walked.as_slice()),
            "a completed grep walk yields the file finder's list, sorted"
        );

        // And it really does land in the cache the next request reads.
        assert!(
            cached_files(&cache, root.to_str().unwrap(), &options)
                .await
                .is_some()
        );
        store_files(
            &cache,
            root.to_str().unwrap(),
            &options,
            outcome.walked.unwrap(),
        )
        .await;
        assert_eq!(
            cached_files(&cache, root.to_str().unwrap(), &options)
                .await
                .unwrap()
                .as_ref(),
            walked.as_ref()
        );

        fs::remove_dir_all(root).unwrap();
    }

    /// `g:simplefinder_grep_cache = 0` opts out of the shared list, and an
    /// older plugin never sends the field at all.  Both promise the pre-0.5
    /// behaviour, so a walk made for such a request must not build a list:
    /// serve() drops it unread, and sending, buffering and sorting one String
    /// per file in the tree — 100k of them on every keystroke that reaches a
    /// monorepo daemon — is exactly the cost the opt-out exists to avoid.
    #[test]
    fn a_grep_that_opted_out_of_the_cache_builds_no_list() {
        let root = temp_project();
        fs::write(root.join("a.txt"), "needle\n").unwrap();
        fs::write(root.join("b.txt"), "nothing\n").unwrap();

        let mut options = grep_options(20);
        options.file_cache = false;
        let outcome = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            options,
            None,
            None,
            &CancellationToken::new(),
        )
        .unwrap();

        assert_eq!(outcome.total, 1, "the grep itself is unaffected");
        assert!(
            outcome.walked.is_none(),
            "a walk nobody asked to share must not collect and sort the tree"
        );

        fs::remove_dir_all(root).unwrap();
    }

    /// The cached list is the whole candidate set: a file missing from it is
    /// not searched, which is what proves the walk was skipped rather than
    /// merely made redundant.
    #[test]
    fn a_cached_grep_reads_the_list_instead_of_the_tree() {
        let root = temp_project();
        fs::write(root.join("a.txt"), "needle\n").unwrap();
        fs::write(root.join("b.txt"), "needle\n").unwrap();

        let walked = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            grep_options(20),
            None,
            None,
            &CancellationToken::new(),
        )
        .unwrap();
        assert_eq!(walked.total, 2, "the walk sees both files");

        let from_full_list = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            grep_options(20),
            Some(Arc::new(vec!["a.txt".to_owned(), "b.txt".to_owned()])),
            None,
            &CancellationToken::new(),
        )
        .unwrap();
        assert_eq!(
            serde_json::to_string(&from_full_list.items).unwrap(),
            serde_json::to_string(&walked.items).unwrap(),
            "the same files produce the same results whichever way they were found"
        );
        assert_eq!(from_full_list.total, walked.total);
        assert!(
            from_full_list.walked.is_none(),
            "a cached grep walked nothing and must not claim to have"
        );

        let partial = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            grep_options(20),
            Some(Arc::new(vec!["a.txt".to_owned()])),
            None,
            &CancellationToken::new(),
        )
        .unwrap();
        assert_eq!(
            partial.items.len(),
            1,
            "only the listed file is searched — the tree is never consulted"
        );
        assert_eq!(partial.items[0].path, "a.txt");

        fs::remove_dir_all(root).unwrap();
    }

    /// A walk the scan ceiling cut short has seen part of the tree.  Caching
    /// that as the project's file list would make every later search blind to
    /// the rest of it, so it must not be published.
    #[test]
    fn a_truncated_walk_publishes_nothing() {
        let root = temp_project();
        let flood: String =
            std::iter::repeat_n("needle\n", GREP_SCAN_CEILING_MIN + 2_000).collect();
        fs::write(root.join("flood.txt"), flood).unwrap();
        fs::write(root.join("quiet.txt"), "nothing\n").unwrap();

        let outcome = handle_grep_sync(
            root.to_str().unwrap(),
            "needle",
            grep_options(1),
            None,
            None,
            &CancellationToken::new(),
        )
        .unwrap();

        assert!(!outcome.total_exact, "the ceiling stopped this scan");
        assert!(
            outcome.walked.is_none(),
            "a partial tree must never be cached as the whole one"
        );

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
            &WalkOptions {
                hidden: false,
                no_ignore: false,
                include_globs: &include,
                exclude_globs: &exclude,
                threads: 0,
            },
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
            &WalkOptions {
                hidden: false,
                no_ignore: false,
                include_globs: &["*.md".to_owned()],
                exclude_globs: &[],
                threads: 0,
            },
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
                file_cache: true,
                threads: 0,
            },
            None,
            None,
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
