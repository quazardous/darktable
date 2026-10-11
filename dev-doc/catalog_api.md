# Catalog API (proposal)

_Status: draft for discussion on darktable-org/darktable#22574. Nothing here
is implemented yet, except the step A functions listed at the end._

darktable's library is a SQLite database. Today about 880 SQL statements reach
it, 194 of them outside `src/common/`: in GUI modules, views, Lua, develop and
control code. This page proposes the API that all catalog access would go
through. It is written before that layer exists so that its shape can be
discussed first.

## Goals and limits

- **Operations, not SQL.** Callers ask for "set the rating of these images" or
  "the film rolls by last access", never for a query string or a
  `sqlite3_stmt`.
- **One behavior.** Moving code behind the API changes nothing a user can see.
  The SQLite backend keeps today's queries.
- **Batch-shaped.** Calls take sets of images and return sets of rows, because
  the current code is full of "loop over ids, one query each" patterns that
  are slow on large libraries.
- **Out of scope:** the schema and its migrations (`common/database.c`), the
  pixelpipe, and GUI state kept in the `memory` schema that only one view
  reads.

## Objects

| Object | Today | Main operations |
| --- | --- | --- |
| image | `main.images` + `dt_image_cache` | read fields, set fields (rating, labels, flags, timestamps, geotag), group, duplicate, remove |
| film roll | `main.film_rolls` | list (by folder, by last access), images of a roll, create, remove empty |
| tag | `data.tags`, `main.tagged_images` | find/create, attach, detach, counts per tag over a set |
| metadata | `main.meta_data` | get, set, remove, counts per key over a set |
| style | `data.styles`, `data.style_items` | list, apply, create from history |
| history | `main.history`, `main.masks_history`, `history_end` | load, write, copy, compress, discard |
| preset | `data.presets` | list for a module, auto-apply matching, write |
| collection | collection rules, `memory.collected_images` | query from rules, ordered result, count, position of an image |
| selection | `main.selected_images` | get, set, add, remove, relative to a collection |

## Targets

A write applies to a **target**, a set of images resolved by the backend:

```c
dt_catalog_target_t dt_catalog_target_ids(const dt_imgid_t *ids, size_t n);
dt_catalog_target_t dt_catalog_target_cursor(const dt_catalog_cursor_t *c);
dt_catalog_target_t dt_catalog_target_selection(void);
dt_catalog_target_t dt_catalog_target_act_on(void);

dt_catalog_status_t dt_catalog_images_set_rating(const dt_catalog_target_t *t, int rating);
dt_catalog_status_t dt_catalog_tags_attach(const dt_catalog_target_t *t, dt_tagid_t tag);
```

`dt_catalog_target_act_on()` is the set a shortcut or a module button acts on.
It follows the act-on rules of `common/act_on.c`: the hovered image first,
unless that is disabled in the preferences, then the selection. These are the
same rules as `dt.gui.action_images` in Lua. It is distinct from the selection
target, which ignores hovering.

## Cursors

A cursor is an ordered snapshot of the ids of a query result. It replaces the
single global `memory.collected_images` table and the "nth / count" iteration
the Lua API does today:

```c
dt_catalog_cursor_t *dt_catalog_query_open(const dt_catalog_query_t *q);
uint32_t dt_catalog_cursor_count(const dt_catalog_cursor_t *c);
int      dt_catalog_cursor_ids(dt_catalog_cursor_t *c, uint32_t offset, uint32_t n,
                               dt_imgid_t *out);
int      dt_catalog_cursor_fetch(dt_catalog_cursor_t *c, uint32_t offset, uint32_t n,
                                 dt_catalog_fields_t fields, dt_catalog_row_t *out);
int64_t  dt_catalog_cursor_rank_of(dt_catalog_cursor_t *c, dt_imgid_t id);
void     dt_catalog_cursor_close(dt_catalog_cursor_t *c);
```

- `fetch` takes a field projection, so the lighttable fills a page of
  thumbnails in one call instead of one query per thumbnail.
- Several cursors can be open at once (lighttable, filmstrip, an export job).
  That is impossible with one global table.
- For the SQLite backend, the current collection's cursor keeps
  `memory.collected_images` as long as some code still reads that table.

## Queries

Collection rules (`common/collection.c`, `_get_query_part()`) become a typed
tree (property, operator, value, and/or/except, sort, grouping) that the SQLite
backend compiles into the same SQL as today. A different backend can take the
tree as it is.

## Aggregates over a set

Several panels need counts over a selection, not rows: the image information
module's "various values", tag and metadata counts in their modules, the
duplicate manager. They become explicit calls:

```c
int dt_catalog_images_distinct_counts(const dt_catalog_target_t *t,
                                      const dt_catalog_field_t *fields, int n, int *counts);
GList *dt_catalog_tags_counts(const dt_catalog_target_t *t);
```

## Writes, transactions, signals

- `dt_database_start/release_transaction` (66 uses) become units of work,
  `dt_catalog_batch_begin()` / `commit()` / `abort()`. Operations that are
  atomic today stay atomic.
- A write raises the same `DT_SIGNAL_*` as today. The signal is raised by the
  API, not by each caller, which removes the "forgot to raise it" class of
  bugs.
- `dt_image_cache` stays the in-memory access to images. It is filled through
  the API, in batches where possible.

## How the step A moves fit

Step A moves each query unchanged into a `src/common/` function. Those
functions are the backend's implementation, and the API is the layer above
them:

| step A function (already moved) | API part |
| --- | --- |
| `dt_film_count`, `dt_film_get_nth`, `dt_image_count`, `dt_image_get_nth`, `dt_tag_get_nth_image`, `dt_styles_get_nth_name` | cursors (`count`, `ids`) |
| `dt_image_foreach_sidecar_row`, `dt_image_get_in_range`, `dt_image_get_outdated_thumbs` | cursor `fetch` with a projection |
| `dt_image_set_flags_list`, `dt_grouping_select_members`, `dt_metadata_remove_keys` | writes on a target |
| `dt_metadata_get_counts`, `dt_tag_get_flags_counts`, `dt_image_count_in_query` | aggregates over a set |
| `dt_image_get/shift/sync_history_end` | history |
| `dt_film_get_by_access`, `dt_film_get_folder` | film rolls |

About 45 functions so far; none of them had to be reshaped to fit.

## Lua

Lua keeps calling the `src/common/` functions, so that every caller goes
through the same code and a breakage is fixed in one place. Those functions
are where this API lives, so Lua does not need a layer of its own.

## Open question

Should presets join this API, or stay a module-side concern (`data.presets`
is not part of an image's catalog)?

## Decided on #22574

- act-on is a target of its own, as above (wpferguson);
- Lua goes through the `common/` functions (wpferguson).
