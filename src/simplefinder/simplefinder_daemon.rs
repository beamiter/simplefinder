use grep_matcher::Matcher;
use grep_regex::RegexMatcher;
use grep_searcher::{sinks::UTF8, Searcher};
use ignore::WalkBuilder;
use nucleo_matcher::{
    pattern::{CaseMatching, Normalization, Pattern},
    Config, Matcher as NucleoMatcher, Utf32Str,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
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
    },
    #[serde(rename = "grep")]
    Grep {
        id: u64,
        root: String,
        pattern: String,
        #[serde(default)]
        regex: bool,
        #[serde(default = "default_max")]
        max: usize,
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
    },
    #[serde(rename = "grep_result")]
    GrepResult {
        id: u64,
        items: Vec<GrepItem>,
        done: bool,
        total: usize,
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

type FileCache = Arc<RwLock<HashMap<String, Arc<Vec<String>>>>>;

async fn get_or_walk_files(
    cache: &FileCache,
    root: &str,
    token: &CancellationToken,
) -> Option<Arc<Vec<String>>> {
    // Check cache first
    {
        let c = cache.read().await;
        if let Some(files) = c.get(root) {
            return Some(Arc::clone(files));
        }
    }

    // Walk
    let root_path = PathBuf::from(root);
    let walker = WalkBuilder::new(&root_path)
        .hidden(false) // include dotfiles
        .git_ignore(true)
        .git_global(true)
        .git_exclude(true)
        .build();

    let mut files = Vec::new();
    for entry in walker {
        if token.is_cancelled() {
            return None;
        }
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        if !entry.file_type().map_or(false, |ft| ft.is_file()) {
            continue;
        }
        if let Ok(rel) = entry.path().strip_prefix(&root_path) {
            files.push(rel.to_string_lossy().into_owned());
        }
    }
    files.sort();

    let files = Arc::new(files);
    {
        let mut c = cache.write().await;
        c.insert(root.to_string(), Arc::clone(&files));
    }
    Some(files)
}

// ─────────────────── Fuzzy matching ───────────────────

fn fuzzy_filter(files: &[String], query: &str, max: usize) -> Vec<FileItem> {
    if query.is_empty() {
        return files
            .iter()
            .take(max)
            .map(|p| FileItem {
                path: p.clone(),
                score: 0,
            })
            .collect();
    }

    let mut matcher = NucleoMatcher::new(Config::DEFAULT);
    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);

    let mut scored: Vec<FileItem> = files
        .iter()
        .filter_map(|p| {
            let mut buf = Vec::new();
            let haystack = Utf32Str::new(p, &mut buf);
            pattern.score(haystack, &mut matcher).map(|score| FileItem {
                path: p.clone(),
                score: score as i64,
            })
        })
        .collect();

    scored.sort_by(|a, b| b.score.cmp(&a.score));
    scored.truncate(max);
    scored
}

// ─────────────────── Grep ───────────────────

fn handle_grep_sync(
    root: &str,
    pattern: &str,
    is_regex: bool,
    max: usize,
    token: &CancellationToken,
) -> Result<Vec<GrepItem>, String> {
    let matcher = if is_regex {
        RegexMatcher::new(pattern).map_err(|e| e.to_string())?
    } else {
        RegexMatcher::new(&regex_syntax::escape(pattern)).map_err(|e| e.to_string())?
    };

    let walker = WalkBuilder::new(root)
        .hidden(false)
        .git_ignore(true)
        .git_global(true)
        .git_exclude(true)
        .build();

    let root_path = Path::new(root);
    let mut results = Vec::new();
    let mut searcher = Searcher::new();

    for entry in walker {
        if token.is_cancelled() || results.len() >= max {
            break;
        }
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        if !entry.file_type().map_or(false, |ft| ft.is_file()) {
            continue;
        }

        let path = entry.path().to_path_buf();
        let rel = path
            .strip_prefix(root_path)
            .unwrap_or(&path)
            .to_string_lossy()
            .into_owned();

        let _ = searcher.search_path(
            &matcher,
            &path,
            UTF8(|lnum, line| {
                if results.len() >= max {
                    return Ok(false);
                }
                let col = matcher
                    .find(line.as_bytes())
                    .ok()
                    .flatten()
                    .map(|m| m.start() + 1)
                    .unwrap_or(1);
                results.push(GrepItem {
                    path: rel.clone(),
                    lnum: lnum as usize,
                    col,
                    text: line.trim_end().to_string(),
                });
                Ok(true)
            }),
        );
    }

    Ok(results)
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
                    let files = match get_or_walk_files(&cache, &root, &token).await {
                        Some(f) => f,
                        None => {
                            // Cancelled during walk
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

                    let items = fuzzy_filter(&files, &query, max);
                    let total = items.len();
                    send_event(
                        &tx,
                        &Event::FilesResult {
                            id,
                            items,
                            done: true,
                            total,
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
                max,
            } => {
                let tx = out_tx.clone();
                let cancels = cancels.clone();
                let token = CancellationToken::new();
                {
                    let mut map = cancels.write().await;
                    map.insert(id, token.clone());
                }

                tokio::spawn(async move {
                    let token_clone = token.clone();
                    let result = tokio::task::spawn_blocking(move || {
                        handle_grep_sync(&root, &pattern, regex, max, &token_clone)
                    })
                    .await;

                    match result {
                        Ok(Ok(items)) => {
                            let total = items.len();
                            send_event(
                                &tx,
                                &Event::GrepResult {
                                    id,
                                    items,
                                    done: true,
                                    total,
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
