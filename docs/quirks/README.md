# The quirk catalog

The inventory of **measured** behaviour SSH Drive depends on: what macOS does
([macos.md](macos.md)) and what a remote server does ([servers.md](servers.md)). A future macOS or
a new kind of server is a **new column in a table**, not a new test.

The catalog is the source of truth for measured behaviour. A row carries the measurement itself:
what was observed, the number or error text it was observed as, and the version or server it was
observed on. Code and design pages that act on a behaviour cite its id.
[testing.md](../design/testing.md) describes the models and scenarios the catalog feeds.

## Entry format

Each behaviour is one row:

| Column | Meaning |
|---|---|
| **id** | `MQ-###` for macOS, `SQ-###` for servers. **Stable for ever.** An id is never reused and never renumbered; a behaviour that stops being true keeps its id and gains a measurement saying so. |
| **statement** | One sentence, present tense, about what *the system* does, with the evidence that supports it. Never about what we do in response — that belongs in the design page named in the source column. |
| **measured on** | Every version or server the behaviour was observed on, each with its date. A version we support and have not measured is written `—`, and that empty cell is a work item, not an assumption. |
| **source** | The design page under `docs/design/` that acts on the behaviour, and the gotcha number where there is one. A `gotcha N` is item N of the numbered list "Things a coder gets wrong without the doc" in the repository's [`CLAUDE.md`](https://github.com/alecdwm/sshdrive/blob/main/CLAUDE.md), which is not part of this site; its numbers are never reused. |
| **scenarios** | The scenario ids in the scenario suites under `Packages/SSHDriveCore/Tests/` (`SystemModelTests`, `AgentRuntimeTests`, `ServerModelTests`) that fail if the behaviour changes and we do not notice. A quirk with no scenario is a quirk nothing is defending. |

Ids are **stable, not sequential**: they are allocated as behaviours are found, so gaps in the
numbering are expected and mean nothing.

| File | Entries |
|---|---|
| [macos.md](macos.md) | 80 |
| [servers.md](servers.md) | 82 |

## Versions and servers

`MQ` rows are measured against a macOS version:

| Short | Full | Where |
|---|---|---|
| **26.4** | macOS 26.4.1 (25E253), Xcode 26.4, arm64, headless | the build VM — almost every measurement |
| **26.6** | macOS 26.6.2 | the owner's own Mac, measured 2026-09-05 and 2026-09-08 |
| **27.0** | macOS 27.0 | the owner's own Mac, measured 2026-09-23 |
| **14** / **15** | macOS 14 / 15 | **the minimum [docs/design/platform.md](../design/platform.md) names. Nothing has been measured there.** Every `14 —` cell in [macos.md](macos.md) is an open question |

`SQ` rows are measured against a testbed service or a real server, not an OS version. The names
are the testbed's (`testbed/README.md`): `deb`, `deb-shells`, `deb-extsftp`, `deb-kbdint`,
`deb-maxsess`, `alp`, `alp-ext`, `alp-nocmin`, `bastion-a`/`bastion-b`/`inner`, `ts-ssh`.

## How a measurement gets here

1. Measure it on the build VM against the testbed, or on a real Mac for what a VM cannot show
   (Finder's drawing, Gatekeeper, TCC, real timing).
2. **New behaviour:** a new id and a row here, with the version and the date. **Changed
   behaviour:** a new measurement on the *existing* id; the old measurement stays. Two
   measurements that disagree are the point of the table. `MQ-061` is one: a quarantined install
   refused on 26.6 and passing on 26.4, and `P3` asserts both without deciding which is right.
3. Teach `SystemModel` or `ServerModel` the rule, keyed on the id. If only the value moved,
   nothing in the model changes.
4. Write or extend a scenario in the scenario suites under `Packages/SSHDriveCore/Tests/` that
   fails if the behaviour changes, and name the id in it. A failure with no scenario is not fixed.
5. `swift test` on Linux across every version in the matrix.

!!! note "The VM measures, it never proves"
    A VM session is finished when the row is here, the model has the rule and the Linux suite is
    green. Adding a whole macOS version has its own checklist in
    [testing.md](../design/testing.md#adding-a-macos-version).

## Where the ids appear in the code

There is no generated mirror of this catalog. The models and the code that acts on a quirk cite
the id in a doc comment, and the scenario tests name the ids they defend:

```sh
grep -rn 'MQ-0' Packages/SSHDriveCore/Sources
grep -rn 'MQ-0' Packages/SSHDriveCore/Tests
```

Two tests check one direction each:

| Test | Fails when |
|---|---|
| `QuirkCatalogueTests` (`SystemModelTests`) | an `MQ` id that `SystemModel`'s quirk table reads is not a row of [macos.md](macos.md), or a modelled id has no measurement covering a supported version |
| `ServerProfileScenarios` (`ServerModelTests`) | an `SQ` id that `ServerModel` keys a rule on is not a row of [servers.md](servers.md), a profile cites an id no rule implements, or a handful of measured values in the profiles differ from the rows |

Nothing checks the other direction: a row no model reads, an id cited in a doc comment, or the
scenarios column of a row. Those citations are added by hand.
