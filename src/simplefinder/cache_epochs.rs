use std::{
    collections::HashMap,
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, Ordering},
    },
};

/// Keep an identity only while a search of this canonical root is alive.
/// Cache entries are independently removed by root; no per-event tombstones.
#[derive(Default)]
pub(super) struct RootEpochs(HashMap<PathBuf, Weak<AtomicBool>>);

#[derive(Clone)]
pub(super) struct RootEpoch(Arc<AtomicBool>);

impl RootEpoch {
    pub(super) fn is_current(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

impl RootEpochs {
    /// Called under the same lock that protects file-cache lookup and publish.
    pub(super) fn begin(&mut self, root: &Path) -> RootEpoch {
        self.0.retain(|_, epoch| epoch.strong_count() != 0);
        let epoch = self.0.entry(root.to_owned()).or_default();
        if let Some(live) = epoch.upgrade() {
            return RootEpoch(live);
        }
        let live = Arc::new(AtomicBool::new(true));
        *epoch = Arc::downgrade(&live);
        RootEpoch(live)
    }

    /// Called under the cache write lock, including when there is no entry.
    pub(super) fn invalidate(&mut self, paths: &[PathBuf]) {
        self.0.retain(|root, epoch| {
            if let Some(live) = epoch.upgrade() {
                if affected(root, paths) {
                    live.store(false, Ordering::Release);
                } else {
                    return true;
                }
            }
            false
        });
    }
}

pub(super) fn affected(root: &Path, paths: &[PathBuf]) -> bool {
    paths
        .iter()
        .any(|path| path.starts_with(root) || root.starts_with(path))
}

/// A rename may name two entries; creation/deletion names one. Do not resolve
/// the final component: the deleted name is already gone, and a symlink's
/// removal changes its parent directory, not the symlink target.
pub(super) fn mutation_paths(values: &[String]) -> Result<Vec<PathBuf>, &'static str> {
    if values.is_empty() || values.len() > 2 {
        return Err("cache invalidation requires one or two local paths");
    }
    values
        .iter()
        .map(|value| {
            let path = Path::new(value);
            if value.len() > 4096
                || !path.is_absolute()
                || value.contains('\0')
                || path.components().any(|part| part == Component::ParentDir)
            {
                return Err("invalid local cache mutation path");
            }
            let Some(parent) = path.parent() else {
                return Err("cache mutation path has no parent");
            };
            let Some(leaf) = path.file_name() else {
                return Err("cache mutation path has no final entry");
            };
            // Exact Tree mutations retain an existing parent. A concurrent
            // delete can remove it before this process handles the event;
            // the absolute lexical path can still retire directly named roots.
            Ok(parent
                .canonicalize()
                .unwrap_or_else(|_| parent.to_owned())
                .join(leaf))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_files_and_grep_epochs_never_become_current_again() {
        let a = Path::new("/work/a");
        let ab = Path::new("/work/ab");
        let mut epochs = RootEpochs::default();
        let before_files = epochs.begin(a);
        let before_grep = epochs.begin(a);
        let unaffected = epochs.begin(ab);
        epochs.invalidate(&[a.join("removed.txt")]);
        let after = epochs.begin(a);
        assert!(!before_files.is_current());
        assert!(!before_grep.is_current());
        assert!(after.is_current());
        assert!(unaffected.is_current());
        epochs.invalidate(&[a.join("renamed.txt")]);
        assert!(!after.is_current());
        assert!(!before_files.is_current());
        assert!(epochs.begin(a).is_current());
    }

    #[test]
    fn renamed_subtree_retires_nested_roots_but_not_prefix_siblings() {
        let renamed = PathBuf::from("/work/dir");
        assert!(affected(Path::new("/work"), &[renamed.clone()]));
        assert!(affected(Path::new("/work/dir/nested"), &[renamed.clone()]));
        assert!(!affected(Path::new("/work/directory"), &[renamed]));
    }

    #[cfg(unix)]
    #[test]
    fn canonicalizes_symlink_parents_but_never_follows_removed_leaf() {
        use std::{fs, os::unix::fs::symlink, time::SystemTime};

        let dir = std::env::temp_dir().join(format!(
            "simplefinder-epoch-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(dir.join("origin")).unwrap();
        fs::create_dir(dir.join("target")).unwrap();
        symlink(dir.join("origin"), dir.join("alias")).unwrap();
        symlink(dir.join("target"), dir.join("origin/leaf")).unwrap();
        let leaf = dir
            .join("alias/leaf")
            .into_os_string()
            .into_string()
            .unwrap();
        let resolved = dir.join("origin").canonicalize().unwrap().join("leaf");
        assert_eq!(
            mutation_paths(std::slice::from_ref(&leaf)).unwrap(),
            [resolved.clone()]
        );
        fs::remove_file(dir.join("origin/leaf")).unwrap();
        assert_eq!(mutation_paths(&[leaf]).unwrap(), [resolved]);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn invalid_paths_neither_expand_scope_nor_accumulate_epochs() {
        for values in [
            vec![],
            vec!["relative".into()],
            vec!["/root/../other".into()],
            vec!["/".into()],
            vec!["/root/null\0name".into()],
            vec!["/a".into(), "/b".into(), "/c".into()],
        ] {
            assert!(mutation_paths(&values).is_err());
        }
        let mut epochs = RootEpochs::default();
        for i in 0..100 {
            let root = PathBuf::from(format!("/root/{i}"));
            assert!(epochs.begin(&root).is_current());
        }
        assert_eq!(epochs.0.len(), 1);
    }
}
