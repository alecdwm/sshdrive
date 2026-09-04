# Milestone 4 spike: S8 and S10, and the read-write matrix

Runbook for the two spikes DESIGN.md section 12 folds into milestone 4, and for the write
matrix section 5.5 specifies. Section 11 has the questions; this file has the steps, the
answer the design expects, and what actually happened. The long-form result lives in
`results.md` under "2026-09-04 (milestone 4) - read-write".

Everything here runs on the headless Mac VM against the Docker testbed on the Mac that
hosts it, over ssh. Two of the S8 answers are Finder drawings and go through the
screenshot recipe recorded in `results.md` (2026-09-04, "what Finder actually draws"):
Screen Recording and Accessibility are granted to `/usr/libexec/sshd-keygen-wrapper` on
this VM, so `screencapture -x` and `osascript` both work from an ssh session.

| Tag | Meaning |
|---|---|
| **VM** | the headless VM plus the testbed. Everything below is this. |
| **screen** | needs `screencapture`; the permission is already granted, see above. |

---

## 0. Setup

### 0.1 Build and install

From the Linux side:

```
scripts/mac-build.sh test     # 355 package tests
scripts/mac-build.sh signed
```

On the Mac:

```
ditto "$HOME/sshdrive/build/Build/Products/Debug/SSH Drive.app" "/Applications/SSH Drive.app"
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" agent restart
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" doctor
```

**Use `agent restart`, not `launchctl kill` plus `open -g`.** launchd brings the agent
back on its own before `ditto` has finished, `open -g` then finds it running and does
nothing, and every measurement below is taken against the *old* binary. That cost an hour
on 2026-09-04; the tell is `sshdrive debug index dump` missing a field the source has.
`sshdrive agent restart` and then a field check (`strings … | grep tagDataBase64`, or
`ping`'s `interfaceVersion`) is the reliable gate.

### 0.2 macOS has no `timeout`

Never `ls` a mount without a deadline. The substitute:

```sh
T() { perl -e "alarm(shift); exec @ARGV" "$@"; }
T 60 ls -la ~/Library/CloudStorage/SSHDrive-m4
```

### 0.3 The two locations

`deb` (2201, Debian, OpenSSH `sftp-server`) is the main target; `alp` (2206, Alpine,
busybox, `internal-sftp`) is the second, for the rename-over-existing and `setstat` paths
on a server that is neither GNU nor OpenSSH's external subsystem.

```sh
# on the server, over a separate ssh
ssh -i ~/.ssh/sshdrive-spike -p 2201 alec@192.168.64.1 '
  rm -rf ~/m4 && mkdir -p ~/m4/Docs ~/m4/Other ~/m4/ro
  printf old > ~/m4/Docs/note.txt ; printf keep > ~/m4/Docs/keep.txt
  mkdir -p ~/m4/Docs/deep && printf x > ~/m4/Docs/deep/x.txt
  ln -s note.txt           ~/m4/Docs/rel-inside
  ln -s ../Other           ~/m4/Docs/rel-parent
  ln -s /home/alec/m4/Other ~/m4/Docs/abs-inside
  ln -s /etc/passwd        ~/m4/Docs/abs-outside
  ln -s ../../etc          ~/m4/Docs/rel-escape
  ln -s nowhere.txt        ~/m4/Docs/dangling
  printf ro > ~/m4/ro/locked.txt && chmod 666 ~/m4/ro/locked.txt && chmod 555 ~/m4/ro'

sshdrive add m4  alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike --path /home/alec/m4
sshdrive add m4a alec@192.168.64.1:2206 --identity ~/.ssh/sshdrive-spike --path /home/alec/m4a
```

`ro` is deliberately a `0666` file inside a `0555` directory: section 5.4's most-argued
row, and the "write to a read-only item" case of the matrix.

### 0.4 A folder is enumerated once, ever

Anything created on the server *after* its parent was listed does not appear in the mount
by itself: change detection is milestone 6. Two hooks stand in for it.

```sh
sshdrive debug policy m4 Docs/does-not-exist inherit   # re-lists Docs (and errors after)
sshdrive debug signal m4                               # signals the working set
```

`debug policy` on a path whose *parent* is known but which is itself missing is the cheap
way to force one directory listing; `debug signal` is what makes the system read the
anchors that listing wrote.

---

## 1. S8 — symlinks

> Return an item with `contentType = .symbolicLink` and `symlinkTargetPath`: does the
> system create a real symlink under CloudStorage, does Finder badge it, does a relative
> target resolve inside the mount, how does Finder present a dangling one, does `ln -s`
> inside the mount reach `createItem` with the target intact so escaping targets can be
> refused?

### s8-1 **VM** Does the system create a real symlink?

```sh
T 60 ls -la  ~/Library/CloudStorage/SSHDrive-m4/Docs
T 20 readlink ~/Library/CloudStorage/SSHDrive-m4/Docs/rel-inside
```

Expect `lrwx------` and the target string the row carries.

**Result (2026-09-04): yes.** `ls -la` shows `lrwx------ 1 alec staff 8 … rel-inside ->`
and `readlink` returns `note.txt`. The five links that pass the check are all real
symlinks; the two that fail are not listed at all.

### s8-2 **VM** Does a relative target resolve inside the mount?

```sh
T 20 cat "$M/Docs/rel-inside"      # -> note.txt
T 20 ls  "$M/Docs/abs-inside/"     # -> ../Other after the rewrite
```

**Result: yes.** `cat` of the link returns `old`, the contents of `note.txt`, so the link
resolves through the mount and the fetch lands on the target's own item. `abs-inside`,
whose server-side target is the absolute `/home/alec/m4/Other`, reads back as `../Other`:
section 5.7's rewrite, done once at enumeration and stored on the row.

### s8-3 **VM** Are escaping targets omitted?

```sh
sshdrive debug index dump m4 | grep -A3 escape
sshdrive debug transport hidden m4
```

**Result: yes, with `hidden = 1` and a reason.**

```
Links/abs-outside  symlink hidden=1 link=''
Links/rel-escape   symlink hidden=1 link=''
"reason" : "the target /etc/passwd is outside this location"
"reason" : "the target ../../etc climbs above this location"
```

Neither is enumerated, neither is in the mount, and `readlink` on either answers "no such
file". `sshdrive status`'s "not shown" list carries both with the reason, which is what
section 5.4 promises for every hidden name.

### s8-4 **screen** How does Finder draw them, dangling or not?

```sh
osascript -e 'tell application "Finder" to open (POSIX file "…/SSHDrive-m4/Docs" as alias)'
osascript -e 'tell application "Finder" to set current view of front window to list view'
screencapture -x ~/m4-shots/s8-docs.png
```

**Result: Kind "Alias", arrow badge, and a dangling link looks exactly like a live one.**
Every link is listed with **Kind "Alias"** and the arrow-badged icon; `abs-inside` and
`rel-parent`, which point at directories, get a badged *folder* icon. `dangling ->
nowhere.txt` is drawn with the same badge and the same Kind, its size the 11 bytes of the
target string, and **no broken-link marker of any kind**. Section 5.7 is corrected to say
so.

### s8-5 **VM** Does `ln -s` reach `createItem` with the target intact?

```sh
T 30 ln -s keep.txt       "$M/Docs/new-rel"
T 30 ln -s ../../../etc   "$M/Docs/new-escape"
T 30 ln -s /etc/passwd    "$M/Docs/new-abs"
```

**Result: yes, and the two escaping ones are refused.** `new-rel` is on the server as
`new-rel -> keep.txt`, byte for byte what was typed. `new-escape` and `new-abs` never
leave the Mac: the server has neither. `ln -s` itself exits 0 in all three cases - the
system takes the item locally first - and `fileproviderctl evaluate` on a refused one
shows the refusal as its `uploadingError`:

```
isUploaded = 0; isUploading = 1;
uploadingError = "Error Domain=NSFileProviderErrorDomain Code=-2005 …"
```

So the message section 5.7 wants the user to read is **not** what the system shows; ours
has to reach them through `sshdrive status`'s sync-error list. Section 5.7 says so now.

### s8-6 **VM** What does enumeration cost?

**Result: one `readlink` per link.** SFTP v3's `readdir` carries attributes but no target,
so the lexical check needs a round trip per link before its row can be built. Once per
link, not once per look; a directory of ordinary files pays nothing. Section 5.7 records
it.

---

## 2. S10 — Finder tags and the xattr hash

> Finder tags on an item whose extension returns `extendedAttributes` from local storage:
> does tagging round-trip, and does the xattr hash in the metadata version stop the system
> re-offering the `modifyItem`? Also check what happens if the version is deliberately left
> unchanged.

Tags cannot be set from a terminal with `tag`; write the xattr instead, which macOS 12 and
later accept as a `tagData` blob:

```sh
HEX=$(python3 -c 'import plistlib,binascii,sys;
sys.stdout.write(binascii.hexlify(plistlib.dumps(["Red\n6","Work\n0"],fmt=plistlib.FMT_BINARY)).decode())')
T 40 xattr -wx com.apple.metadata:_kMDItemUserTags "$HEX" "$M/Docs/keep.txt"
```

### s10-1 **VM** Does a tag round-trip, and how does it arrive?

```sh
sshdrive debug xattr m4 Docs/keep.txt
/usr/bin/log show --last 3m --predicate 'subsystem == "org.shirls.sshdrive"' --info --style compact | grep modifyItem
```

**Result: yes, as `tagData` and nothing else.**

```
modifyItem Docs/keep.txt changedFields=0x10 xattrKeys=- tagData=453 bytes
```

`0x10` is `NSFileProviderItemTagData`; the `extendedAttributes` dictionary is **empty**,
exactly as section 5.4 predicted. The 453-byte blob is an `NSKeyedArchiver` archive, not
the `_kMDItemUserTags` property list the xattr holds, which is why the row stores and
serves it opaquely. The metadata version moved with it:

```
"xattrHash" : "cbf29ce484222325"  ->  "e2a2e7907f0e585a"
"metadataVersion" : "4-1788515228-0:420:2001:2001:111:6:0:e2a2e7907f0e585a"
```

and nothing at all reached the server (`getfattr -d` on the file: no xattrs; mtime and
size unchanged).

### s10-2 **VM** Do the tags survive an eviction and a re-download?

```sh
sshdrive debug evict m4 Docs/keep.txt
T 30 cat "$M/Docs/keep.txt" >/dev/null
T 30 xattr -l "$M/Docs/keep.txt"
```

**Result: yes.** After the evict-and-refetch the replica has
`com.apple.metadata:_kMDItemUserTags` again, rebuilt by the system from the `tagData` the
item returned, plus a `com.apple.FinderInfo` of the system's own. This is the S4 loss the
whole design of section 5.4 exists to prevent, and it does not happen.

### s10-3 **VM** Does the hash stop the system re-offering the change?

```sh
/usr/bin/log show … | grep -c "modifyItem Docs/keep.txt changedFields=0x10"   # over 60 s
```

**Result: one call. And also one call with the version frozen.**

```sh
sshdrive debug fault m4 --frozen-metadata on      # reply with the version the item had
T 40 xattr -wx com.apple.metadata:_kMDItemUserTags "$HEX2" "$M/Docs/note.txt"
```

**1** `modifyItem` in sixty seconds either way. So the hash is **not** what stops a retry
loop: there is no retry loop on 26.4, for the same reason a `modifyItem` reply is believed
at all (S3, 2026-09-04). What the hash is actually for is the other direction - it is the
only thing that moves an item's version when the *agent* changes the stored blob, which a
restore from the index backup does - and section 5.4 says so now.

### s10-4 **screen** What does Finder draw?

**Result: the dot, on the item and on any link that points at it.** `keep.txt` carries a
red dot, `note.txt` green; the aliases `new-rel` and `rel-inside` show their *target's*
colour, because `xattr` and Finder both follow a symlink. Worth knowing before reading
`xattr <link>` as evidence about the link.

---

## 3. The write matrix (section 5.5)

Every step is checked server-side over a separate ssh, never through the mount.

| # | Step | Expected | Result 2026-09-04 |
|---|---|---|---|
| 1 | `printf hello > $M/Docs/created.txt` | temp file, non-overwriting rename, mode 0644 | `-rw-r--r-- 5 … created.txt`, contents `hello`; no `.sshdrive-upload-*` left |
| 2 | create then `chmod +x` a new script | 0755 through the rename | `-rwxr-xr-x 18 … run.sh` |
| 3 | `printf appended >> created.txt` | `posix-rename` overwrite, mode kept | `-rw-r--r-- 13`, `helloappended` |
| 4 | `touch -t 202401021530.45` | mtime set back, whole seconds | Mac `2024-01-02 15:30:45` local = server `04:30:45` UTC |
| 5 | `mv created.txt renamed.txt` | plain rename | server shows `renamed.txt` |
| 6 | `mv Docs/renamed.txt Other/moved.txt` | rename across directories | `Other/moved.txt`, gone from `Docs` |
| 7 | `mv Docs/deep Other/deep` | directory subtree, one rename, paths rewritten | `Other/deep/x.txt` |
| 8 | `rm Other/moved.txt` | `remove` | gone |
| 9 | `rmdir Other/deep` (non-empty) | refused, item left in place | `rmdir: Directory not empty`; server still has it |
| 10 | `rm -r Other/deep` | recursive walk on the server | gone, depth first |
| 11 | `printf clobber > ro/locked.txt` | locked up front, never attempted | `Operation not permitted` locally; server file untouched |
| 12 | `chmod +x Docs/keep.txt`, then `-x` | `.fileSystemFlags` -> `setstat` | `0644 -> 0755 -> 0644` on the server |
| 13 | create onto a taken name | `lstat`-confirmed collision | `"Docs/keep.txt" already exists on the server.` |
| 14 | `printf … > $M/Docs/.DS_Store` | swallowed | **never reaches the extension at all** (below) |

Row 11 is the one worth reading twice. The row the agent derived is
`ro/locked.txt mode=666 caps=65 fsFlags=2` - reading and evicting only, no write bit -
so the kernel refuses the write from the served flags and nothing is ever sent. That is
section 5.4's "shown locked rather than failing at save time", end to end.

### 3.1 `.DS_Store`

**Result: the system keeps it and never tells us.** No `createItem`, no `modifyItem`, no
row in the index, nothing on the server, and `fileproviderctl evaluate` reports it as an
ordinary item with `isUploaded = 0` and `isUploading = 0`. It survives a listing that does
not mention it. So the local-only path (`hidden = 3`, `local_content`) is not exercised by
the case it was written for; it is kept for any other writer of a `.DS_Store` and because
the exclusion is the system's choice rather than a contract. Section 5.4 corrected.

### 3.2 Stale temp files

```sh
# on the server
cd ~/m4/Docs
touch .sshdrive-upload-<mac8>-deadbeef            # ours
touch .sshdrive-upload-99999999-fresh             # another Mac, new
touch -d "40 days ago" .sshdrive-upload-99999999-old
sshdrive debug policy m4 Docs/does-not-exist inherit    # one listing
```

**Result: exactly section 5.5.**

```
removed a stale upload temp file: Docs/.sshdrive-upload-deadbeef-deadbeef
removed a stale upload temp file: Docs/.sshdrive-upload-99999999-old
```

The other Mac's fresh one is left alone. `<mac8>` is the `macID` at the top of
`config.json`.

### 3.3 The conflict copy

The conflict window is one round trip wide, so it has to be held open on purpose:

```sh
sshdrive debug fault m4 --upload-delay 9000        # hold between the bytes and the lstat
( T 90 sh -c 'printf LOCALEDIT2 > "$M/Docs/c2.txt"' ) &
sleep 3
ssh … 'printf REMOTECHANGE-YYYYY > ~/m4/Docs/c2.txt'   # change it underneath
wait ; sleep 25
sshdrive debug fault m4 --upload-delay 0
```

**Result: the copy lands, the remote wins, and the eviction needs a retry.**

```
conflict on Docs/c2.txt: base 4-1788515833-0, server 18-1788515842-0
conflict copy Docs/c2 (conflicted copy from chosen-newt 2026-09-04 at 19.57.28).txt kept the local content
Docs/c2.txt changed on the server; … the remote item was returned
evicted 9E7D237E-… after a conflict copy on attempt 1
```

Server-side: `c2.txt` is the 18-byte remote content and the copy is the 10-byte local
edit. Through the mount, `c2.txt` is `dataless true` and `cat` returns
`REMOTECHANGE-YYYYY`, and the copy is listed beside it.

**The assumption that failed.** The first pass of this test evicted **once**, straight
after the reply, and was refused:

```
"errorDescription" : "The file ‘conflict.txt‘ cannot be evicted.", "errorCode" : -2008
```

`-2008` is `NSFileProviderErrorNonEvictable`: the system is still finishing the
modification it has just been told about. The same call a few seconds later succeeds. The
conflict path now retries with a doubling backoff from 0.25 s (seven attempts) and
signals the working set as well, without which the new sibling's anchor is a row nobody
asks for and Finder never shows the copy - a folder is enumerated once, ever (section
6.5). Section 5.5 and section 13 corrected.

### 3.4 A lost master

```sh
for p in $(pgrep -f "sshdrive-<id8>"); do kill -9 $p; done
T 120 sh -c 'printf AFTERLOSS > "$M/Docs/afterloss4.txt"'
```

Two traps. `pgrep` keeps listing the killed children as zombies until the agent reaps
them, so count live ones with `ps -o stat` rather than trusting `pgrep`. And a location
that has been restarted can hold **two** masters, so kill them all or the write simply
succeeds on the survivor.

**Result: `serverUnreachable`, pending, offline.**

```
uploadingError = "… Code=-1004 "Your device couldn’t connect to the server. …""
enumeratorForPendingItems: count 1
sshdrive list: m4 … mounted  offline
```

Which is what section 5.6 asks for until milestone 5's breaker and reconnection exist. The
queued write does **not** flush by itself when the agent comes back: nothing reconnects the
location until something asks it to, and that is milestone 5.

---

## 4. busybox and `internal-sftp` (`alp`, 2206)

The same matrix against Alpine's busybox and sshd's built-in SFTP subsystem, for the two
paths that are server-shaped rather than client-shaped.

| Question | Result 2026-09-04 |
|---|---|
| `sshdrive debug transport rename-check m4a` | `renameRefusesAnExistingName: true`, `preflight: not needed` |
| create with `chmod +x` | `-rwxr-xr-x … x.sh`: the `setstat` after the rename is honoured |
| modify keeps the mode | `-rw-r--r-- 7 … note.txt`, `oldmore` |
| create onto a taken name | `"Docs/keep.txt" already exists on the server.` |
| `chmod +x` on an existing file | `0644 -> 0755` on the server |
| `rmdir` a non-empty directory | refused; `rm -r` takes it |
| symlink policy | `rel -> note.txt` shown, `esc -> /etc/passwd` omitted |
| capability report | `5/8 optimal`, `posix-rename@openssh.com` and `fsync@openssh.com` both offered |

`internal-sftp` on Alpine offers the same OpenSSH extensions as the external
`sftp-server`, so nothing in section 5.5 degrades there. The rename-semantics probe of
section 5.5 is what would notice a server that did not, and it runs once per location, in
the location root, leaving nothing behind.

---

## 5. Debug hooks this milestone added

```
sshdrive debug fault <name> [--upload-delay MS] [--frozen-metadata on|off]
sshdrive debug transport rename-check <name>
sshdrive debug xattr <name> <path>            # now also tagData, the xattr hash and hidden
sshdrive debug index dump <name>              # now also linkTarget
```

- **`--upload-delay MS`** holds every upload open between the bytes landing in the temp
  file and the `lstat` of the destination, which is section 5.5's conflict window. It is
  the only way to make a **real** conflict rather than a simulated one: change the file on
  the server inside the window.
- **`--frozen-metadata on`** makes `modifyItem` reply with the metadata version the item
  had *before* the change. That is S10's control case for the xattr hash.
- **`transport rename-check`** runs section 5.5's rename-semantics probe now and reports
  what it found: whether a plain `rename` refuses a name that is already taken, and
  whether every create and rename therefore takes an `lstat` preflight.
- **`debug xattr`** prints the stored blob's FNV-1a hash beside the metadata version it
  feeds, the `tagData` base64 and its length, and the row's `hidden` value.

**Turn every fault off before leaving the VM**, `--upload-delay 0` and
`--frozen-metadata off` included; `sshdrive debug transfers <name>` prints all six.

---

## 6. State the VM should be left in

No locations, no File Provider domains, no `~/Library/CloudStorage` entries, no control
sockets, `~/m4` and `~/m4a` removed from both servers (`chmod -R u+w ~/m4` first: the
`ro` directory is `0555` on purpose), and every fault off. `sshdrive doctor` green apart
from the two expected warnings.
