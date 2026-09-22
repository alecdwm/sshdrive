# The quirk catalog

This directory is the inventory of **measured** behaviour that SSH Drive depends on: what macOS
does (`macos.md`) and what a remote server does (`servers.md`). It exists so that a future macOS
or a new kind of server is a **new column in a table**, not a new test; `docs/design/testing.md`
is the architecture it feeds.

The catalog is the source of truth for measured behaviour. A row carries the measurement itself:
what was observed, the number or the error text it was observed as, and the version or server it
was observed on. Code and design pages that act on a behaviour cite its id.

## Entry format

Each behaviour is one row:

| Column | Meaning |
|---|---|
| **id** | `MQ-###` for macOS, `SQ-###` for servers. **Stable for ever.** An id is never reused and never renumbered; a behaviour that stops being true keeps its id and gains a measurement saying so. |
| **statement** | One sentence, present tense, about what *the system* does, with the evidence that supports it. Never about what we do in response — that belongs in the design page named in the source column. |
| **measured on** | Every version or server the behaviour was observed on, each with its date. A version we support and have not measured is written `—`, and that empty cell is a work item, not an assumption. |
| **source** | The design page under `docs/design/` that acts on the behaviour, and the `CLAUDE.md` gotcha number where there is one. |
| **scenarios** | The scenario ids in the scenario suites under `Packages/SSHDriveCore/Tests/` (`SystemModelTests`, `AgentRuntimeTests`, `ServerModelTests`) that fail if the behaviour changes and we do not notice. A quirk with no scenario is a quirk nothing is defending. |

## Versions

`MQ` rows are measured against a macOS version. The versions that appear:

| Short | Full | Where |
|---|---|---|
| **26.4** | macOS 26.4.1 (25E253), Xcode 26.4, arm64, headless | the build VM — almost every measurement |
| **26.6** | macOS 26.6.2 | the owner's own Mac, measured 2026-09-05 and 2026-09-08 |
| **14** / **15** | macOS 14 / 15 | **the minimum `docs/design/platform.md` names. Nothing has been measured there.** Every `14 —` cell in `macos.md` is an open question |

`SQ` rows are measured against a testbed service or a real server, not an OS version. The names
are the testbed's (`testbed/README.md`): `deb`, `deb-shells`, `deb-extsftp`, `deb-kbdint`,
`deb-maxsess`, `alp`, `alp-ext`, `alp-nocmin`, `bastion-a`/`bastion-b`/`inner`, `ts-ssh`.

## How a measurement gets here

1. Measure it on the build VM against the testbed, or on a real Mac for what a VM cannot show
   (Finder's drawing, Gatekeeper, TCC, real timing).
2. **New behaviour** → a new id and a row here, with the version and the date. **Changed
   behaviour** → a new measurement on the *existing* id; the old measurement stays. Two
   measurements that disagree are the whole point of the table.
3. Teach `SystemModel` / `ServerModel` the rule, keyed on the id.
4. Write or extend a scenario in the scenario suites under `Packages/SSHDriveCore/Tests/` (`SystemModelTests`, `AgentRuntimeTests`, `ServerModelTests`) that fails if the behaviour changes, and
   name the id in it.
5. `swift test` on Linux across every version in the matrix.

**The VM measures, it never proves.** A VM session is finished when the row is here and the Linux
suite is green.

## Where the ids appear in the code

There is no generated mirror of this catalog. The models and the code that acts on a quirk cite
the id in a doc comment (`grep -rn 'MQ-0' Packages/SSHDriveCore/Sources`), and the scenario tests
name the ids they defend (`grep -rn 'MQ-0' Packages/SSHDriveCore/Tests`). Nothing checks that the
three sets agree; adding a row means adding the citations by hand.

## Counts

| File | Entries |
|---|---|
| `macos.md` | 80 |
| `servers.md` | 82 |

Ids are **stable, not sequential**: they are allocated as behaviours are found and are never
reused, so gaps in the numbering are expected and mean nothing.
