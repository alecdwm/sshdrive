# The quirk catalog

This directory is the inventory of **measured** behaviour that SSH Drive depends on: what macOS
does (`macos.md`) and what a remote server does (`servers.md`). It exists so that a future macOS
or a new kind of server is a **new column in a table**, not a new test — see
`docs/testing-architecture.md` for the architecture it feeds.

`docs/spikes/results.md` is the source of truth. This catalog adds no facts of its own; every
entry points back at the results entry that measured it. If the two disagree, `results.md` wins
and the catalog is wrong.

## Entry format

Each behaviour is one row:

| Column | Meaning |
|---|---|
| **id** | `MQ-###` for macOS, `SQ-###` for servers. **Stable for ever.** An id is never reused and never renumbered; a behaviour that stops being true keeps its id and gains a measurement saying so. |
| **statement** | One sentence, present tense, about what *the system* does. Never about what we do in response — that belongs in the DESIGN.md section named in the source column. |
| **measured on** | Every version or server the behaviour was observed on, each with its date. A version we support and have not measured is written `—`, and that empty cell is a work item, not an assumption. |
| **source** | The `results.md` entry (date plus heading or sub-question id), the DESIGN.md section, and the `CLAUDE.md` gotcha number where there is one. |
| **scenarios** | The scenario ids in `Tests/ScenarioTests/` that fail if the behaviour changes and we do not notice. A quirk with no scenario is a quirk nothing is defending. |

## Versions

`MQ` rows are measured against a macOS version. The versions that appear:

| Short | Full | Where |
|---|---|---|
| **26.4** | macOS 26.4.1 (25E253), Xcode 26.4, arm64, headless | the build VM — almost every measurement |
| **26.6** | macOS 26.6.2 | the owner's own Mac — the first real cask install (2026-09-05) and the 0.1.2 field failure (2026-09-08) |
| **14** / **15** | macOS 14 / 15 | **DESIGN.md §2's minimum. Nothing has been measured there.** Every `14 —` cell in `macos.md` is an open question |

`SQ` rows are measured against a testbed service or a real server, not an OS version. The names
are the testbed's (`testbed/README.md`): `deb`, `deb-shells`, `deb-extsftp`, `deb-kbdint`,
`deb-maxsess`, `alp`, `alp-ext`, `alp-nocmin`, `bastion-a`/`bastion-b`/`inner`, `ts-ssh`.

## How a measurement gets here

1. Measure on the VM against the testbed, as a runbook step in `docs/spikes/`.
2. Write the dated entry in `docs/spikes/results.md`.
3. **New behaviour** → a new id and a row here. **Changed behaviour** → a new measurement on the
   *existing* id; the old measurement stays. Two measurements that disagree are the whole point
   of the table.
4. Teach `SystemModel` / `ServerModel` the rule, keyed on the id.
5. Write or extend a scenario if the measurement exposed a failure.
6. `swift test` on Linux across every version in the matrix.

The rule behind all of it: **the VM measures, it never proves.** A VM session that ends without a
`results.md` entry, a row here and a green Linux suite has not finished.

## Machine-readable mirror

`Sources/SystemModel/Quirks/macos.json` and `Sources/ServerModel/Quirks/servers.json` carry the
same ids with one row per (quirk, version, value, source). `scripts/check-quirks.sh` asserts that
the Markdown ids, the JSON ids, the ids the models read and the scenario ids referenced here all
agree; it runs in the Linux CI job.

## Counts

| File | Entries |
|---|---|
| `macos.md` | 75 |
| `servers.md` | 71 |

Ids are **stable, not sequential**: they are allocated as behaviours are found and are never
reused, so gaps in the numbering are expected and mean nothing.
