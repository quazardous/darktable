# Helios - phase 0: catalog SDK

Branch: `helios/phase0-catalog-sdk` - base: `darktable-org/darktable` master `8c64bf7` (2026-10-09).

## Goal

Replace direct SQLite access with an **in-process catalog SDK written in C**, with **strictly
identical** behavior ("iso"). No network, no API: phase 0 only creates the boundary.
Later phases will plug a remote backend (Helios vault) in behind this boundary.

Phase 0 exit criteria:

1. no SQLite call outside the SDK's `sqlite` backend (checked in CI by `tools/helios/sql_inventory.py --check`);
2. the whole GUI, Lua, `develop/`, `control/` and `mcp/` go through the SDK;
3. no observable difference in behavior: same databases produced, same XMP, same collection
   results, same performance within ±5% on lighttable operations.

## Measured state (inventory)

See [`sql-inventory.md`](sql-inventory.md) (generated). Highlights:

| measure | value |
|---|---|
| SQL call sites | 881 in 78 files |
| outside `common/` (step A) | 246 sites - `libs/` 85, `develop/` 37, `dtgtk/` 28, `gui/` 28, `lua/` 20, `control/` 19, `views/` 17, `mcp/` 9 |
| in `common/` excluding schema (step B) | 349 sites |
| schema and migrations (`common/database.c`) | 286 sites - stay in the backend as is |
| dynamic SQL | ~150 sites (queries built with `g_strdup_printf`, mostly collections and filters) |
| multi-schema queries (`main` / `data` / `memory`) | ~95 |
| active triggers | 4 (cleanup of `makers` / `models` / `lens` / `cameras` after image deletion) - internal to the backend |
| views | `v_images` |

Most coupled domains: `images` (238 sites), `history` (139), `tags` (84), `presets` (82, of which 67 in
the GUI), `selection` (74), `collection` (55, including `memory.collected_images` shared by the whole GUI).

## Principles

- **Iso first.** Each step is a pure refactoring. No bug fix or behavior change is mixed in with
  moving code; bugs found are noted and fixed separately.
- **Business domains, not disguised SQL.** The SDK exposes operations (`set_rating`, `attach_tag`,
  `history_load`...) and never an SQL string or a `sqlite3_stmt`.
- **Designed for remote, implemented locally.** The signatures assume from now on that a call
  may cross the network: batch operations, targets rather than lists of IDs, cursors,
  field projections. No signature may require cheap random access to the database.
- **Upstreamable.** Step A (no more SQL in the GUI) improves darktable independently of
  Helios: it is split into small, reviewable PRs, domain by domain.

## SDK architecture

```
src/common/catalog/
├── catalog.h              entry point, common types, targets, errors
├── catalog_cursor.h       query cursors
├── catalog_query.h        query model (replaces the dynamic SQL of collections)
├── catalog_<domain>.h     images, film, history, tags, labels, ratings, metadata, styles,
│                          presets, locations, selection
├── backend.h              function table implemented by each backend
└── sqlite/                sqlite backend: the current SQL, moved
```

### Backend

One function table per domain, selected at initialization (`dt_catalog_init()`, called in place
of direct access to `darktable.db`). Phase 0 has only one backend, `sqlite`, which contains the
existing SQL; `common/database.c` (schema, migrations, maintenance, snapshots) becomes internal to this backend.

### Targets

Batch writes apply to a **target**, resolved by the backend:

```c
dt_catalog_target_t dt_catalog_target_ids(const dt_imgid_t *ids, size_t n);
dt_catalog_target_t dt_catalog_target_cursor(const dt_catalog_cursor_t *c);
dt_catalog_target_t dt_catalog_target_selection(const dt_catalog_selection_t *s);
dt_catalog_target_t dt_catalog_target_query(const dt_catalog_query_t *q);

dt_catalog_status_t dt_catalog_images_set_rating(const dt_catalog_target_t *t, int rating);
```

Locally, a "cursor" target is a join on the cursor's table; remotely, it avoids
sending millions of IDs.

Decision (2026-10-10): the **cursor** is the main target; the **ids** target is kept for
operations on one or a few images. The `selection` and `query` targets remain to be confirmed in
step C.

### Cursors

They replace `memory.collected_images`, which is currently unique and global. A cursor is the **ordered
snapshot** of the IDs of a query result:

```c
dt_catalog_cursor_t *dt_catalog_query_open(const dt_catalog_query_t *q, dt_catalog_cursor_flags_t flags);
uint32_t dt_catalog_cursor_count(const dt_catalog_cursor_t *c);
uint64_t dt_catalog_cursor_version(const dt_catalog_cursor_t *c);
int      dt_catalog_cursor_ids(dt_catalog_cursor_t *c, uint32_t offset, uint32_t n, dt_imgid_t *out);
int      dt_catalog_cursor_fetch(dt_catalog_cursor_t *c, uint32_t offset, uint32_t n,
                                 dt_catalog_fields_t fields, dt_catalog_row_t *out);
int64_t  dt_catalog_cursor_rank_of(dt_catalog_cursor_t *c, dt_imgid_t id);
void     dt_catalog_cursor_watch(dt_catalog_cursor_t *c, dt_catalog_cursor_changed_cb cb, gpointer data);
void     dt_catalog_cursor_close(dt_catalog_cursor_t *c);
```

- direct access to a position (scrollbar), position of an image, traversal, grouping of grouped
  images, manual order (`position`);
- field **projection** to fill thumbnails in a single batch call (no N+1);
- **version** and change notification (delta of insertions/deletions) hooked to the existing
  signals (`DT_SIGNAL_COLLECTION_CHANGED`, etc.);
- several simultaneous cursors (lighttable, filmstrip, export) - impossible today.

sqlite backend: one ordered temporary table per cursor in the `memory` schema. For iso, the
"current collection" cursor keeps the name `memory.collected_images` as long as unmigrated code reads it.

### Query model

Collection rules (`common/collection.c`, `_get_query_part()`) are currently translated into
SQL fragments. They become a typed query tree (property, operator, value, combination,
sort, grouping) that the sqlite backend compiles into SQL - the same SQL as today, for iso - and that a
remote backend will be able to pass on as is.

### Selection

Stays stored in `main.selected_images` in phase 0 (iso), but is only accessible through
`catalog_selection.h`, expressed relative to a cursor. Moving to a purely client-side state is
a phase 1 decision.

### Transactions and consistency

`dt_database_start/release/rollback_transaction` (66 uses) become **SDK units of
work** (`dt_catalog_batch_begin/commit/abort`). Operations that were atomic stay atomic; callers
no longer see an SQL transaction.

### Existing caches

`dt_image_cache` remains the access point to images; it is filled through the SDK (in batches when
possible) instead of reading the database itself.

## Breakdown

### Step A - no more SQL outside `common/`

Each PR handles one domain: the callers' SQL (GUI, Lua, develop, control, views, mcp) is moved
into existing or new `common/` functions, with no behavior change.

Proposed order (from simplest to riskiest):

1. ratings and color labels
2. metadata
3. tags
4. film rolls and images
5. locations, overlays
6. styles
7. presets (67 sites in the GUI: `gui/presets.c`, `libs/lib.c`, `libs/modulegroups.c`...)
8. history and masks (`develop/develop.c`, `develop/imageop.c`) - critical, reinforced tests
9. selection and collection (`dtgtk/thumbtable.c`, `dtgtk/culling.c`, `views/`, `libs/collect.c`)
10. `mcp/dt_bridge.c`

At the end of step A, `sql_inventory.py --check` passes and goes into CI.

### Step B - the SDK interface

The `common/` functions are grouped behind the `catalog_*.h` headers and their SQL moved into
`common/catalog/sqlite/`. Same order of domains.

### Step C - cursors, targets, query model

Replacement of `memory.collected_images` by cursors, of the dynamic SQL of collections by the
query model, of ID lists by targets.

## Iso validation

- **Unit tests** (cmocka, `src/tests/unittests/`) for each SDK function, on an in-memory database.
- **Database equivalence tests**: a scripted scenario (import, ratings, tags, history, styles,
  virtual copies, deletion) run before and after each PR; the SQL dumps of the databases and the XMP
  produced must be identical.
- Existing darktable **integration tests** (rendering): unchanged.
- **Performance**: time to open and scroll a collection of 100,000 images, before/after.
- **Inventory** regenerated at each PR: the number of sites outside the backend must only decrease.

## Working method per domain

1. read the domain's sites in [`sql-inventory.json`](sql-inventory.json);
2. move the SQL into `common/` functions, existing ones where possible;
3. build without warnings, run the unit tests;
4. run the equivalence bench before and after (`tools/helios/bench/run.sh`, plus a GUI bench such as
   `tools/helios/bench/gui_labels.sh` when the code path is only reached from the lighttable);
5. regenerate the inventory: the step A counter must go down;
6. stop at a staged change with a proposed commit message.

## Tooling and known limits

- regenerate the inventory:

      python3 -I tools/helios/sql_inventory.py --json doc/helios/sql-inventory.json --markdown doc/helios/sql-inventory.md

- The inventory counts a site where a query is prepared, not where a query prepared elsewhere is
  stepped (e.g. a statement prepared in `views/` and run from `dtgtk/thumbnail.c`), and table
  attribution is approximate for dynamic SQL (~150 sites).
- The equivalence bench (`tools/helios/bench/`) runs darktable offscreen in a wbox compositor
  (`tools/helios/wbox`) through `--luacmd`. "Lua as a library" mode races with darktable's async Lua threads (upstream
  bug, to report), hence `--luacmd`.
- (2026-10-11) Bench determinism: darktable writes back image structs copied before decoding a full
  image (`common/mipmap_cache.c`, DT_MIPMAP_FULL; upstream darktable-org/darktable#22569), which undid
  ratings set by the scenario whenever a background job loaded a raw meanwhile. The bench disables the
  thumbnail crawler (`backthumbs_mipsize=never`), builds every thumbnail synchronously before each
  state dump (`settle()` in scenario.lua, so the lighttable never loads a raw behind the scenario's
  back), only compares sidecars of images still in the library, and sorts XMP attributes. 10
  consecutive runs byte-identical on an idle machine; heavy CPU load (a parallel build) can still
  expose late writes, so do not bench while building.
- (2026-10-11) Test tiers and rules (darktable #3713): unit and catalog API tests on every build
  (`ctest`, about a second); `tools/helios/bench/check.sh <before> <after> [domains|auto]` on every
  domain commit (budget 5 min); all GUI benches and `perf.sh` before a PR. A new bench gates nothing
  until 5 consecutive identical runs, and a bench that diverges once is fixed at the root, never
  retried.
- (2026-10-11) Keeping up with upstream: `check.sh` fetches `upstream/master` and says how many
  commits the branch is behind. Rebase (not merge: the series feeds upstream PRs) at the start of a
  lot, never in the middle of one: `git rebase --exec 'cmake --build build' upstream/master`, so
  every commit still builds, then `ctest` and `check.sh`, then push to the fork with
  `--force-with-lease`.
- (2026-10-11) Pixel integration tests (T2, darktable #3766): the full suite
  (`tools/helios/bench/integration.sh <prefix> <log>`, 191 tests, OpenCL off) runs once on the base
  as the reference, with its known failures recorded, then once on the branch at the end of each
  domain; never per lot, since step A does not touch the pixelpipe. Heavy jobs never overlap:
  `check.sh`, `integration.sh`, `perf.sh` and `timeline.sh` take a shared lock
  (`tools/helios/bench/lock.sh`) and a second one waits. Builds are not covered by the lock: do not
  build while one of them runs. Each `darktable-cli` already uses every core, and a full pass under
  a parallel build took ~40 s per test instead of ~10. `integration.sh` refuses to start with less
  than 5 GB free: a full disk on 2026-10-11 left the outputs of the last tests unwritten.
- (2026-10-11) GUI benches over D-Bus (darktable #3823): `gui_metadata.sh`, `gui_labels.sh` and
  `gui_tags.sh` start darktable once on a private session bus (`bus_start` in
  `tools/helios/bench/lib.sh`) and drive it with `dtlua '<lua chunk>'`, a `gdbus` call to
  `org.darktable.service.Remote.Lua`. A Lua error comes back as `org.darktable.Error.LuaError` and
  `dtlua` exits 1. This replaced one darktable start per step: gui_metadata 51 s to 23 s,
  gui_labels 32 s to 15 s, gui_tags 33 s to 15-19 s. Three things the timings depend on:
  `init_dirs` writes a fresh darktablerc without the init session; the password store is off
  (`plugins/pwstorage/pwstorage_backend=none`), otherwise libsecret waits 25 s for a keyring that
  does not exist in wbox; `gui_tags` hides the bottom panel, whose timeline refreshes late after
  `collect.filter()` and failed one run in five. `darktable-cli` has no D-Bus service.
- (2026-10-11) Thread count: `darktable-cli -t N` with N below the core count overflows per-thread
  buffers (`dt_alloc_perthread`): `InitializeMagick` resets OpenMP to every core after `dt_init` set
  N. Until upstream darktable-org/darktable#22438 lands, run pixel tests with N equal to the core
  count, or on a build with the fix. `tools/helios/bench/threads_compare.sh` compares outputs across
  thread counts.
- (2026-10-11) Before reporting a result, follow the checklist in `AGENTS.local.md` ("Before
  reporting anything"): a run counts only if it produced its output, a log is read only once the job
  is finished, hashes and issue numbers are copied from `git`/`gh`, and every comparison has a
  control run in the same conditions.
- (2026-10-11) Pixel references (darktable #3786, upstream darktable-org/darktable#22589): the
  `expected.png` files are made on TurboGit's machine with a RelWithDebInfo build, which has no
  `-ffast-math`. TurboGit's nightly results are committed in the integration submodule
  (`logs/YYYY/test-*.log`); the one of 2026-10-08 fails only `0178-contrast-texture`, which is
  upstream's own failure list. Here, on base 8c64bf7ca, a `--build-type Release` build
  (`-O3 -ffast-math`, `src/CMakeLists.txt:796`, plus `-march=native`) failed 29 tests; 18 pass on
  RelWithDebInfo (9 only failed with `-ffast-math` and `-march=native` together, 9 with
  `-ffast-math` alone). Of the 11 left, 0179/0180 need the spektrafilm data pack, which the
  suite's fresh config does not have (`src/iop/spektrafilm.c:46-51`), 0178 fails upstream too, and
  8 are just over the tolerance (avg dE 0.03-0.6, not explained). So run pixel tests on a
  RelWithDebInfo build (build.sh's default), and judge a change by base vs branch outputs on the
  same build (`HELIOS_KEEP_OUTPUTS`), not by `expected.png`.
- (2026-10-13) Parallel pixel runners at fewer threads each (darktable #3768): not adopted. With
  the `-t` fix, the fast subset is byte-identical at 1, 2, 4 and 8 OpenMP threads except
  `0045-vignetting` (t1 503741 px, t2 370008 px, max 13/255 against t4; t8 identical). Vignette's
  dithering keeps one TEA state per thread and reseeds only `tea_state[0]` per row
  (`src/iop/vignette.c:780`), so its noise depends on how rows are split across threads. Running N
  suites at 12/N threads would test a split no user runs, so the suite keeps one runner at the
  core count. Revisit if vignette's dithering becomes independent of the thread count. Upstream
  also confirmed `0179-spektrafilm` as a known failure (darktable-org/darktable#22589).
