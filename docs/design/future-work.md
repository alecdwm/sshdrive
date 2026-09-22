# Future work

Not planned for v1, recorded so the design leaves room for them:

- **Move detection at the polling tiers.** In one diff cycle, a vanished
  directory and a new one with the same child names, sizes and mtimes could
  be reported as a rename, keeping identifiers and cached content.
- **One-time-code logins.** Servers that require a fresh code on every
  connection could be supported by a `sshdrive unlock <name>` that answers
  the next prompt interactively.
- **Finder aliases as remote symlinks.** A `createItem` whose content type is
  an alias file could be resolved on the Mac side; if the bookmark points
  inside the same domain, create a remote symlink instead of uploading the
  alias file.
- **Selective offline profiles**, such as "keep everything opened in the
  last 7 days", built on the same pin markers.
- **Server-side trash**, if users ask for "Put Back".
- **inotify / fswatch as a change-detection tier** between sweep and the
  helper, for accounts with exec whose cache directory is `noexec` and
  whose OS/arch the helper does not cover. The design, kept here so it
  need not be worked out again: two `inotifywait -m
  -P -q --no-newline --format '%e%0%w%f%0'` processes per location under
  one wrapper (recursive for pin roots, flat for the working set), `-P`
  mandatory because `-r` otherwise follows symlinks out of the share,
  `modify` left out of the event list since `close_write` reports the
  finished write, `moved_from`/`moved_to` as delete + create because the
  rename cookie is not exposed, watch-limit and overflow errors dropping
  to sweep, watcher restarts debounced per root set, and `fswatch -r -0
  --event-flags` on macOS and BSD. It is out of v1 because it is the
  most code for the narrowest audience, needs a tool installed on the
  server, and cannot report renames; adding a helper target for the
  platform in question is usually cheaper.
- **Submitting the cask to homebrew-cask** so the tap is unnecessary.

## Not yet measured

- The helper's kqueue path has never run on a BSD: the testbed has no BSD server, so
  `freebsd/x86_64` links and is shipped untested.
- `linux/armv7` links and is shipped; no hardware has run it.
- The pinning page's re-assert net, which answers an eviction that reaches a kept item, has
  no route to fire on macOS 26.4 and has never fired.
- Nothing in the quirk catalogue has been measured on macOS 14 or 15, the minimum this
  design names.
