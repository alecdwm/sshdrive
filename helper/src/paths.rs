//! Paths, the root set, and the ignore list.
//!
//! Every path this binary reports is **relative to the location root**, in the exact
//! spelling the index stores (DESIGN.md section 5.3), so the agent can put it straight
//! through the `RelativePath` constructor (section 9.1). Paths are bytes end to end: a
//! server filename need not be valid UTF-8 (section 5.4).

use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

/// Section 6.4's "fixed, short ignore list": our own upload temp files and editor scratch
/// names. `.git` is deliberately **not** on it - a repository browsed through the mount
/// must show a current `.git` or `git status` inside it acts on stale objects.
pub const IGNORED: &[&str] = &[".sshdrive-upload-*", ".*.swp", "*~", ".#*", "4913"];

/// True when the *basename* matches one of the patterns above. Only `*` is a wildcard;
/// the list is fixed and none of it needs more.
pub fn is_ignored(name: &[u8]) -> bool {
    IGNORED.iter().any(|pattern| glob(pattern.as_bytes(), name))
}

/// A `*`-only matcher, iterative so a pathological name cannot blow the stack.
fn glob(pattern: &[u8], name: &[u8]) -> bool {
    let (mut p, mut n) = (0usize, 0usize);
    let (mut star, mut mark) = (None, 0usize);
    while n < name.len() {
        if p < pattern.len() && pattern[p] == b'*' {
            star = Some(p);
            mark = n;
            p += 1;
        } else if p < pattern.len() && pattern[p] == name[n] {
            p += 1;
            n += 1;
        } else if let Some(s) = star {
            p = s + 1;
            mark += 1;
            n = mark;
        } else {
            return false;
        }
    }
    while p < pattern.len() && pattern[p] == b'*' {
        p += 1;
    }
    p == pattern.len()
}

/// The scope the helper watches, as the agent sends it (section 6.5's root set).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RootSet {
    /// Watched one level deep: the `materialized` and `viewed` reasons.
    pub shallow: Vec<Vec<u8>>,
    /// Watched recursively: pin roots.
    pub recursive: Vec<Vec<u8>>,
    /// Subtrees pruned out of a recursive root (section 7.1.1).
    pub excluded: Vec<Vec<u8>>,
}

impl RootSet {
    pub fn len(&self) -> usize {
        self.shallow.len() + self.recursive.len()
    }

    /// True when `path` (relative, bytes) is inside an excluded subtree.
    pub fn is_excluded(&self, path: &[u8]) -> bool {
        self.excluded.iter().any(|e| is_at_or_under(path, e))
    }
}

/// `path == prefix` or `path` starts with `prefix/`. Byte comparison: a name is bytes.
pub fn is_at_or_under(path: &[u8], prefix: &[u8]) -> bool {
    if prefix.is_empty() {
        return true;
    }
    if path == prefix {
        return true;
    }
    path.len() > prefix.len() && path.starts_with(prefix) && path[prefix.len()] == b'/'
}

/// Joins a relative path to the absolute root. An empty relative path is the root itself.
pub fn absolute(root: &Path, relative: &[u8]) -> PathBuf {
    if relative.is_empty() {
        return root.to_path_buf();
    }
    let mut bytes = root.as_os_str().as_bytes().to_vec();
    if bytes.last() != Some(&b'/') {
        bytes.push(b'/');
    }
    bytes.extend_from_slice(relative);
    PathBuf::from(OsString::from_vec(bytes))
}

/// The containment check of section 9.1 as a value. Not on the event path - every event
/// is assembled from a watch descriptor whose relative path we already hold - but it is
/// what the tests below pin the rule to, and what a future watcher that learns a path
/// from the kernel rather than from us must go through.
#[allow(dead_code)]
/// The other direction: an absolute path back to the index's spelling, or `None` when it
/// is not under the root at all.
///
/// This is the containment check of section 9.1 on this side of the wire. Nothing that
/// fails it is ever reported, so a watch that somehow ended up outside the root - a
/// directory replaced by a symlink between the `lstat` and the `inotify_add_watch` - can
/// produce no event the agent would act on.
pub fn relative(root: &Path, absolute: &Path) -> Option<Vec<u8>> {
    let root_bytes = root.as_os_str().as_bytes();
    let path_bytes = absolute.as_os_str().as_bytes();
    if path_bytes == root_bytes {
        return Some(Vec::new());
    }
    let root_bytes = if root_bytes.last() == Some(&b'/') {
        &root_bytes[..root_bytes.len() - 1]
    } else {
        root_bytes
    };
    if path_bytes.len() > root_bytes.len()
        && path_bytes.starts_with(root_bytes)
        && path_bytes[root_bytes.len()] == b'/'
    {
        Some(path_bytes[root_bytes.len() + 1..].to_vec())
    } else {
        None
    }
}

/// A relative path with one component appended.
pub fn join(relative: &[u8], name: &[u8]) -> Vec<u8> {
    if relative.is_empty() {
        return name.to_vec();
    }
    let mut out = Vec::with_capacity(relative.len() + 1 + name.len());
    out.extend_from_slice(relative);
    out.push(b'/');
    out.extend_from_slice(name);
    out
}

/// True when the relative path contains no `.` or `..` component and no empty component,
/// which is what the agent's own constructor requires. A root the agent sent is trusted;
/// this catches a path assembled from a kernel event on a tree that moved underneath us.
pub fn is_well_formed(relative: &[u8]) -> bool {
    if relative.is_empty() {
        return true;
    }
    relative
        .split(|&b| b == b'/')
        .all(|component| !component.is_empty() && component != b"." && component != b"..")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_ignore_list_is_exactly_section_6_4s() {
        for name in [
            ".sshdrive-upload-a1b2c3d4-DEADBEEF",
            ".notes.txt.swp",
            "draft~",
            ".#lockfile",
            "4913",
        ] {
            assert!(is_ignored(name.as_bytes()), "{name} should be ignored");
        }
    }

    #[test]
    fn git_is_deliberately_not_ignored() {
        for name in ["\u{2e}git", "index.html", "notes.swp", "49130", "a4913"] {
            assert!(!is_ignored(name.as_bytes()), "{name} must not be ignored");
        }
        assert!(!is_ignored(b".git"));
        assert!(!is_ignored(b".gitignore"));
    }

    #[test]
    fn containment_is_a_byte_comparison_of_whole_components() {
        assert!(is_at_or_under(b"a/b", b"a"));
        assert!(is_at_or_under(b"a", b"a"));
        assert!(is_at_or_under(b"anything", b""));
        assert!(!is_at_or_under(b"ab", b"a"));
        assert!(!is_at_or_under(b"a", b"a/b"));
    }

    #[test]
    fn relative_refuses_a_path_outside_the_root() {
        let root = Path::new("/home/alec/share");
        assert_eq!(relative(root, Path::new("/home/alec/share")), Some(Vec::new()));
        assert_eq!(relative(root, Path::new("/home/alec/share/a/b")), Some(b"a/b".to_vec()));
        assert_eq!(relative(root, Path::new("/home/alec/shareholder/x")), None);
        assert_eq!(relative(root, Path::new("/etc/passwd")), None);
    }

    #[test]
    fn a_trailing_slash_on_the_root_changes_nothing() {
        assert_eq!(relative(Path::new("/x/"), Path::new("/x/y")), Some(b"y".to_vec()));
        assert_eq!(absolute(Path::new("/x/"), b"y"), PathBuf::from("/x/y"));
        assert_eq!(absolute(Path::new("/x"), b""), PathBuf::from("/x"));
    }

    #[test]
    fn non_utf8_names_survive_the_round_trip() {
        let root = Path::new("/r");
        let raw = [0x61u8, 0xff, 0xfe];
        let abs = absolute(root, &raw);
        assert_eq!(relative(root, &abs).unwrap(), raw.to_vec());
    }

    #[test]
    fn dot_dot_never_passes() {
        assert!(is_well_formed(b"a/b"));
        assert!(is_well_formed(b""));
        assert!(!is_well_formed(b"a/../b"));
        assert!(!is_well_formed(b"./a"));
        assert!(!is_well_formed(b"a//b"));
    }

    #[test]
    fn exclusions_prune_whole_subtrees() {
        let set = RootSet { excluded: vec![b"pin/big".to_vec()], ..Default::default() };
        assert!(set.is_excluded(b"pin/big"));
        assert!(set.is_excluded(b"pin/big/deep/file"));
        assert!(!set.is_excluded(b"pin/bigger"));
    }
}
