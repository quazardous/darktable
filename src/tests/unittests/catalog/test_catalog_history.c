/*
    This file is part of darktable,
    Copyright (C) 2026 darktable developers.

    darktable is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    darktable is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with darktable.  If not, see <http://www.gnu.org/licenses/>.
*/


#include <stdarg.h>
#include <stddef.h>
#include <setjmp.h>
#include <cmocka.h>

#include "catalog_fixture.h"
#include "common/database.h"
#include "common/debug.h"
#include "common/history.h"

static int _count_history(const dt_imgid_t imgid)
{
  int count = -1;
  sqlite3_stmt *stmt;
  DT_DEBUG_SQLITE3_PREPARE_V2(dt_database_get(darktable.db),
                              "SELECT COUNT(*) FROM main.history WHERE imgid = ?1", -1, &stmt, NULL);
  DT_DEBUG_SQLITE3_BIND_INT(stmt, 1, imgid);
  if(sqlite3_step(stmt) == SQLITE_ROW) count = sqlite3_column_int(stmt, 0);
  sqlite3_finalize(stmt);
  return count;
}

static void test_insert_and_count(void **state)
{
  const dt_imgid_t imgid = dt_test_catalog_image("mire1.cr2");
  const int before = dt_history_count_items(imgid);
  assert_int_equal(before, _count_history(imgid));

  const int params[2] = { 7, 11 };
  const char blend[4] = { 0 };
  dt_history_insert_item(imgid, before, 3, "flip", params, sizeof(params), blend, sizeof(blend), 14);
  assert_int_equal(dt_history_count_items(imgid), before + 1);

  sqlite3_stmt *stmt;
  DT_DEBUG_SQLITE3_PREPARE_V2(dt_database_get(darktable.db),
                              "SELECT num, module, enabled, blendop_version, multi_priority, multi_name"
                              " FROM main.history WHERE imgid = ?1 AND operation = 'flip'",
                              -1, &stmt, NULL);
  DT_DEBUG_SQLITE3_BIND_INT(stmt, 1, imgid);
  assert_int_equal(sqlite3_step(stmt), SQLITE_ROW);
  assert_int_equal(sqlite3_column_int(stmt, 0), before);
  assert_int_equal(sqlite3_column_int(stmt, 1), 3);
  assert_int_equal(sqlite3_column_int(stmt, 2), 1);
  assert_int_equal(sqlite3_column_int(stmt, 3), 14);
  assert_int_equal(sqlite3_column_int(stmt, 4), 0);
  assert_string_equal((const char *)sqlite3_column_text(stmt, 5), " ");
  sqlite3_finalize(stmt);

  // flip.c asks this to decide whether to convert the legacy flip bits
  assert_true(dt_history_check_module_exists(imgid, "flip", FALSE));
  assert_false(dt_history_check_module_exists(dt_test_catalog_image("bayer4.crw"), "flip", FALSE));
}

static void test_find_module_version(void **state)
{
  const dt_imgid_t imgid = dt_test_catalog_image("hlrecovery.arw");
  const float params[3] = { 0.25f, 0.5f, 0.75f };
  const float other[3] = { 0.25f, 0.5f, 1.0f };
  const char blend[4] = { 0 };
  dt_history_insert_item(imgid, dt_history_count_items(imgid), 5, "exposure",
                         params, sizeof(params), blend, sizeof(blend), 14);

  int version = -1;
  assert_true(dt_history_find_module_version("exposure", params, sizeof(params), &version));
  assert_int_equal(version, 5);

  version = -1;
  assert_false(dt_history_find_module_version("exposure", other, sizeof(other), &version));
  assert_false(dt_history_find_module_version("colorin", params, sizeof(params), &version));
  assert_int_equal(version, -1);
}

static void _exec(const char *sql)
{
  DT_DEBUG_SQLITE3_EXEC(dt_database_get(darktable.db), sql, NULL, NULL, NULL);
}

static int _count(const char *sql)
{
  int count = -1;
  sqlite3_stmt *stmt;
  DT_DEBUG_SQLITE3_PREPARE_V2(dt_database_get(darktable.db), sql, -1, &stmt, NULL);
  if(sqlite3_step(stmt) == SQLITE_ROW) count = sqlite3_column_int(stmt, 0);
  sqlite3_finalize(stmt);
  return count;
}

static void test_get_rows(void **state)
{
  const dt_imgid_t imgid = dt_test_catalog_image("bayer4.crw");
  const int base = dt_history_count_items(imgid);
  const int params[2] = { 3, 4 };
  const char blend[3] = { 1, 2, 3 };
  dt_history_insert_item(imgid, base + 1, 7, "colorin", params, sizeof(params), blend, sizeof(blend), 12);
  dt_history_insert_item(imgid, base, 6, "exposure", params, sizeof(params), blend, sizeof(blend), 13);
  // a NULL multi_name and empty blobs, as an old or damaged row may have
  gchar *sql = g_strdup_printf("INSERT INTO main.history"
                               " (imgid, num, module, operation, op_params, enabled,"
                               "  blendop_params, blendop_version, multi_priority, multi_name,"
                               "  multi_name_hand_edited)"
                               " VALUES (%d, %d, 1, 'flip', x'', 0, NULL, 1, 2, NULL, 1)",
                               imgid, base + 2);
  _exec(sql);
  g_free(sql);

  GList *rows = dt_history_get_rows(imgid, -1);
  assert_int_equal(g_list_length(rows), base + 3);

  // by num, whatever the insertion order
  const dt_history_row_t *r0 = g_list_nth_data(rows, base);
  const dt_history_row_t *r1 = g_list_nth_data(rows, base + 1);
  const dt_history_row_t *r2 = g_list_nth_data(rows, base + 2);
  assert_int_equal(r0->id, imgid);
  assert_int_equal(r0->num, base);
  assert_string_equal(r0->operation, "exposure");
  assert_int_equal(r0->module_version, 6);
  assert_int_equal(r0->blendop_version, 13);
  assert_int_equal(r1->num, base + 1);
  assert_string_equal(r1->operation, "colorin");
  assert_int_equal(r1->enabled, 1);
  assert_int_equal(r1->op_params_size, sizeof(params));
  assert_memory_equal(r1->op_params, params, sizeof(params));
  assert_int_equal(r1->blendop_params_size, sizeof(blend));
  assert_memory_equal(r1->blendop_params, blend, sizeof(blend));
  assert_int_equal(r1->multi_priority, 0);
  assert_string_equal(r1->multi_name, " ");

  assert_string_equal(r2->operation, "flip");
  assert_null(r2->op_params);
  assert_int_equal(r2->op_params_size, 0);
  assert_null(r2->blendop_params);
  assert_int_equal(r2->blendop_params_size, 0);
  assert_int_equal(r2->enabled, 0);
  assert_int_equal(r2->multi_priority, 2);
  assert_null(r2->multi_name);
  assert_int_equal(r2->multi_name_hand_edited, 1);
  g_list_free_full(rows, dt_history_row_free);

  assert_null(dt_history_get_rows(imgid, 4242));
}

static void test_snapshot_memory(void **state)
{
  const dt_imgid_t imgid = dt_test_catalog_image("mire1.cr2");
  const float params[1] = { 2.0f };
  const char blend[2] = { 0 };
  dt_history_insert_item(imgid, dt_history_count_items(imgid), 1, "highlights",
                         params, sizeof(params), blend, sizeof(blend), 14);
  const int n = dt_history_count_items(imgid);

  dt_history_clear_memory();
  gchar *sql = g_strdup_printf("INSERT INTO memory.history SELECT * FROM main.history WHERE imgid = %d",
                               imgid);
  _exec(sql);
  g_free(sql);
  assert_int_equal(_count("SELECT COUNT(*) FROM memory.history"), n);

  dt_history_snapshot_memory(17);
  dt_history_clear_memory();
  assert_int_equal(_count("SELECT COUNT(*) FROM memory.history"), 0);

  // the snapshot rows carry the snapshot id, not the image id
  GList *rows = dt_history_get_rows(imgid, 17);
  GList *main_rows = dt_history_get_rows(imgid, -1);
  assert_int_equal(g_list_length(rows), n);
  for(GList *r = rows, *m = main_rows; r && m; r = g_list_next(r), m = g_list_next(m))
  {
    const dt_history_row_t *s = r->data;
    const dt_history_row_t *o = m->data;
    assert_int_equal(s->id, 17);
    assert_int_equal(s->num, o->num);
    assert_string_equal(s->operation, o->operation);
    assert_int_equal(s->op_params_size, o->op_params_size);
  }
  g_list_free_full(rows, dt_history_row_free);
  g_list_free_full(main_rows, dt_history_row_free);
  _exec("DELETE FROM memory.snapshot_history");
}

static void test_get_masks_rows(void **state)
{
  const dt_imgid_t imgid = dt_test_catalog_image("hlrecovery.arw");
  const float points[4] = { 0.1f, 0.2f, 0.3f, 0.4f };
  const float source[2] = { 0.5f, 0.6f };
  for(int num = 0; num < 3; num++)
  {
    sqlite3_stmt *stmt;
    DT_DEBUG_SQLITE3_PREPARE_V2(dt_database_get(darktable.db),
                                "INSERT INTO main.masks_history"
                                " (imgid, num, formid, form, name, version, points, points_count, source)"
                                " VALUES (?1, ?2, ?3, 1, ?4, 6, ?5, 2, ?6)",
                                -1, &stmt, NULL);
    DT_DEBUG_SQLITE3_BIND_INT(stmt, 1, imgid);
    DT_DEBUG_SQLITE3_BIND_INT(stmt, 2, 2 - num);
    DT_DEBUG_SQLITE3_BIND_INT(stmt, 3, 100 + num);
    DT_DEBUG_SQLITE3_BIND_TEXT(stmt, 4, num ? "circle" : "path", -1, SQLITE_TRANSIENT);
    DT_DEBUG_SQLITE3_BIND_BLOB(stmt, 5, points, sizeof(points), SQLITE_TRANSIENT);
    DT_DEBUG_SQLITE3_BIND_BLOB(stmt, 6, source, sizeof(source), SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
  }

  // below history_end only, by num
  GList *rows = dt_history_get_masks_rows(imgid, -1, 2);
  assert_int_equal(g_list_length(rows), 2);
  const dt_history_masks_row_t *m0 = rows->data;
  const dt_history_masks_row_t *m1 = rows->next->data;
  assert_int_equal(m0->num, 0);
  assert_int_equal(m0->formid, 102);
  assert_int_equal(m1->num, 1);
  assert_int_equal(m1->formid, 101);
  assert_int_equal(m0->type, 1);
  assert_string_equal(m0->name, "circle");
  assert_int_equal(m0->version, 6);
  assert_int_equal(m0->points_count, 2);
  assert_int_equal(m0->points_size, sizeof(points));
  assert_memory_equal(m0->points, points, sizeof(points));
  assert_int_equal(m0->source_size, sizeof(source));
  assert_memory_equal(m0->source, source, sizeof(source));
  g_list_free_full(rows, dt_history_masks_row_free);

  // a snapshot reads its own table, by snapshot id
  gchar *sql = g_strdup_printf("INSERT INTO memory.snapshot_masks_history"
                               " SELECT 9, * FROM main.masks_history WHERE imgid = %d",
                               imgid);
  _exec(sql);
  g_free(sql);
  rows = dt_history_get_masks_rows(imgid, 9, 10);
  assert_int_equal(g_list_length(rows), 3);
  g_list_free_full(rows, dt_history_masks_row_free);
  assert_null(dt_history_get_masks_rows(imgid, 8, 10));
  _exec("DELETE FROM memory.snapshot_masks_history");
}

static void test_write_item(void **state)
{
  const dt_imgid_t imgid = dt_test_catalog_image("bayer4.crw");
  dt_history_delete_rows(imgid);
  assert_int_equal(dt_history_next_num(imgid), 0);

  const int params[2] = { 1, 2 };
  const char blend[2] = { 9, 8 };
  // a missing row is inserted
  dt_history_write_item(imgid, 0, "exposure", params, sizeof(params), 6, 1,
                        blend, sizeof(blend), 13, 0, "first", 1);
  assert_int_equal(dt_history_next_num(imgid), 1);

  // an existing row is updated in place, not duplicated
  const int other[2] = { 3, 4 };
  dt_history_write_item(imgid, 0, "exposure", other, sizeof(other), 7, 0,
                        blend, sizeof(blend), 14, 2, "second", 0);
  dt_history_write_item(imgid, 3, "colorin", params, sizeof(params), 2, 1,
                        blend, sizeof(blend), 13, 0, "", 0);
  assert_int_equal(dt_history_count_items(imgid), 2);
  assert_int_equal(dt_history_next_num(imgid), 4);

  GList *rows = dt_history_get_rows(imgid, -1);
  assert_int_equal(g_list_length(rows), 2);
  const dt_history_row_t *r = rows->data;
  assert_int_equal(r->num, 0);
  assert_string_equal(r->operation, "exposure");
  assert_int_equal(r->module_version, 7);
  assert_int_equal(r->enabled, 0);
  assert_memory_equal(r->op_params, other, sizeof(other));
  assert_int_equal(r->blendop_version, 14);
  assert_int_equal(r->multi_priority, 2);
  assert_string_equal(r->multi_name, "second");
  assert_int_equal(r->multi_name_hand_edited, 0);
  g_list_free_full(rows, dt_history_row_free);
}

static void test_masks_item_and_delete(void **state)
{
  const dt_imgid_t imgid = dt_test_catalog_image("mire1.cr2");
  const float points[6] = { 1, 2, 3, 4, 5, 6 };
  const float source[3] = { 0.1f, 0.2f, 0.3f };
  dt_history_insert_masks_item(imgid, 0, 77, 2, "brush", 6, points, sizeof(points), 3,
                               source, sizeof(source));

  GList *rows = dt_history_get_masks_rows(imgid, -1, 1);
  assert_int_equal(g_list_length(rows), 1);
  const dt_history_masks_row_t *m = rows->data;
  assert_int_equal(m->formid, 77);
  assert_int_equal(m->type, 2);
  assert_string_equal(m->name, "brush");
  assert_int_equal(m->version, 6);
  assert_int_equal(m->points_count, 3);
  assert_memory_equal(m->points, points, sizeof(points));
  assert_int_equal(m->source_size, sizeof(source));
  g_list_free_full(rows, dt_history_masks_row_free);

  // the image's history and mask history go, and nothing of another image
  const dt_imgid_t other = dt_test_catalog_image("hlrecovery.arw");
  const int keep = dt_history_count_items(other);
  dt_history_delete_rows(imgid);
  assert_int_equal(dt_history_count_items(imgid), 0);
  assert_null(dt_history_get_masks_rows(imgid, -1, 100));
  assert_int_equal(dt_history_count_items(other), keep);
}

int main(int argc, char *argv[])
{
  const struct CMUnitTest tests[] = {
    cmocka_unit_test(test_insert_and_count),
    cmocka_unit_test(test_find_module_version),
    cmocka_unit_test(test_get_rows),
    cmocka_unit_test(test_snapshot_memory),
    cmocka_unit_test(test_get_masks_rows),
    cmocka_unit_test(test_write_item),
    cmocka_unit_test(test_masks_item_and_delete),
  };
  return cmocka_run_group_tests(tests, dt_test_catalog_setup, dt_test_catalog_teardown);
}
