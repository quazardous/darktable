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

int main(int argc, char *argv[])
{
  const struct CMUnitTest tests[] = {
    cmocka_unit_test(test_insert_and_count),
    cmocka_unit_test(test_find_module_version),
  };
  return cmocka_run_group_tests(tests, dt_test_catalog_setup, dt_test_catalog_teardown);
}
