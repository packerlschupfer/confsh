# confsh RFC #3 — file-backed config provider (bind PoC)

A runnable proof-of-concept for
[halcycon/confsh#3](https://github.com/halcycon/confsh/issues/3): bringing
**file-based** services (bind, ISC dhcpd, …) under a confsh-style
`configure` / `set` / `show` / `commit` / `rollback` workflow, without
breaking confsh's "UCI is the only source of truth" rule for UCI configs.

This is **not** wired into confsh core — it's a standalone sketch of the
*mechanism* and the *provider interface*, so the design in #3 is concrete
and reviewable. ucode, so it drops into confsh's world directly.

## The idea

confsh's dialect layer maps EdgeOS paths onto **UCI**. File-based daemons
(bind, dhcpd, strongswan's legacy mode) have no UCI, so they're invisible
to `configure`/`commit`. A **provider** teaches confsh how to own a set of
files while *reusing the same commit/rollback guarantees*:

```
 user ── set/delete ──► session copy of the owned files
                        │
      show / compare ◄──┤ diff(session, live)
                        │
      commit ───────────┼─► validate(session)          e.g. named-checkzone
                        ├─► archive(live)               revision for rollback
                        ├─► freeze(zone)                dynamic-DNS safety
                        ├─► session ─► live             atomic file replace
                        └─► thaw(zone)                  reload the daemon
      rollback N ───────┼─► freeze ─► archive[N] ─► live ─► thaw
```

Nothing is a shadow store: the provider edits the **real** files, validates
them before they go live, and uninstalling leaves them intact — the same
contract confsh already offers for UCI.

## Provider interface

A provider implements (see the `bind` object in `fb.uc`):

| hook | purpose |
|------|---------|
| `files(dir, zone)` | the files it owns (under `dir`) |
| `parse(dir, zone)` | files → a structured value confsh can show/edit |
| `render(dir, zone, parsed)` | structured value → files (here: bumps the SOA serial) |
| `validate(dir, zone)` | gate the commit (`named-checkzone`) |
| `freeze` / `thaw(zone)` | **the dynamic-zone hazard from #3**: a zone under dynamic update must be `rndc freeze`-d before its file is edited and `rndc thaw`-ed after, or journalled updates are lost |

## The dynamic-DNS hazard (why this isn't just "edit a file")

bind zones under dynamic update keep in-memory changes + a `.jnl` journal.
Editing the zone file underneath `named` and reloading **loses** those. So
`commit`/`rollback` here wrap the live-file replace in `rndc freeze` …
`rndc thaw`. That single detail is the main reason file-backed config needs
a real design, not a `sed` in a dialect module.

## Run it

```sh
./run-demo.sh          # in the openwrt/rootfs container (podman), like confsh tests
```

The demo adds records, shows the diff, commits (validate + archive + freeze/
thaw), commits again, then **rolls back** and shows the record gone.
`named-checkzone` and `rndc` are stubbed in `bin/` so it runs without bind
installed; on a real box the provider calls the real tools.

## Status / scope

PoC only. Manages `A`/`AAAA`/`CNAME` records in one zone to demonstrate the
lifecycle. A real version would: integrate with confsh's session/archive
dirs and `commit-confirm` timer, add a path grammar
(`service dns zone … record …`), redact secrets (TSIG keys) from archives,
and add providers for ISC dhcpd etc.
