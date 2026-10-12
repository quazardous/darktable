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
#include "common/collection.h"
#include "common/colorlabels.h"
#include "common/metadata.h"
#include "common/selection.h"
#include "common/tags.h"

static void test_colorlabels(void **state)
{
  const dt_imgid_t cr2 = dt_test_catalog_image("mire1.cr2");
  assert_true(dt_is_valid_imgid(cr2));
  assert_int_equal(dt_colorlabels_get_labels(cr2), 0);

  dt_colorlabels_set_label(cr2, DT_COLORLABELS_RED);
  dt_colorlabels_set_label(cr2, DT_COLORLABELS_BLUE);
  assert_int_equal(dt_colorlabels_get_labels(cr2),
                   (1 << DT_COLORLABELS_RED) | (1 << DT_COLORLABELS_BLUE));
  assert_true(dt_colorlabels_check_label(cr2, DT_COLORLABELS_BLUE));
  assert_false(dt_colorlabels_check_label(cr2, DT_COLORLABELS_GREEN));

  dt_colorlabels_remove_label(cr2, DT_COLORLABELS_RED);
  assert_int_equal(dt_colorlabels_get_labels(cr2), 1 << DT_COLORLABELS_BLUE);
  dt_colorlabels_remove_all_labels(cr2);
  assert_int_equal(dt_colorlabels_get_labels(cr2), 0);
}

static void test_tags(void **state)
{
  const dt_imgid_t cr2 = dt_test_catalog_image("mire1.cr2");
  const dt_imgid_t arw = dt_test_catalog_image("hlrecovery.arw");
  guint tagid = 0, found = 0;
  assert_true(dt_tag_new("test|catalog", &tagid));
  assert_true(dt_tag_exists("test|catalog", &found));
  assert_int_equal(found, tagid);
  gchar *name = dt_tag_get_name(tagid);
  assert_string_equal(name, "test|catalog");
  g_free(name);

  dt_tag_attach(tagid, arw, FALSE, FALSE);
  dt_tag_attach(tagid, cr2, FALSE, FALSE);
  assert_int_equal(dt_tag_images_count(tagid), 2);
  GList *images = dt_tag_get_images(tagid);
  assert_int_equal(g_list_length(images), 2);
  assert_non_null(g_list_find(images, GINT_TO_POINTER(cr2)));
  assert_non_null(g_list_find(images, GINT_TO_POINTER(arw)));
  g_list_free(images);

  dt_tag_detach(tagid, arw, FALSE, FALSE);
  assert_int_equal(dt_tag_images_count(tagid), 1);
}

static void test_metadata(void **state)
{
  const dt_imgid_t crw = dt_test_catalog_image("bayer4.crw");
  dt_metadata_set(crw, "Xmp.dc.title", "a title", FALSE);

  uint32_t count = 0;
  GList *res = dt_metadata_get(crw, "Xmp.dc.title", &count);
  assert_int_equal(count, 1);
  assert_string_equal((const char *)res->data, "a title");
  g_list_free_full(res, g_free);

  GList *imgs = g_list_prepend(NULL, GINT_TO_POINTER(crw));
  dt_metadata_clear(imgs, FALSE);
  g_list_free(imgs);
  res = dt_metadata_get(crw, "Xmp.dc.title", &count);
  assert_int_equal(count, 0);
  g_list_free_full(res, g_free);
}

static void test_list_rows(void **state)
{
  gboolean has_query = FALSE;
  GList *rows = dt_collection_list_rows(DT_COLLECTION_PROP_CAMERA, "1=1", FALSE, &has_query);
  assert_true(has_query);
  int total = 0;
  for(GList *l = rows; l; l = g_list_next(l))
  {
    const dt_collection_list_row_t *r = l->data;
    assert_non_null(r->text);
    total += r->count;
  }
  assert_int_equal(total, 3);
  g_list_free_full(rows, dt_collection_list_row_free);

  // the film rolls: one, holding the three images
  rows = dt_collection_list_rows(DT_COLLECTION_PROP_FILMROLL, "1=1", FALSE, &has_query);
  assert_true(has_query);
  assert_int_equal(g_list_length(rows), 1);
  assert_int_equal(((dt_collection_list_row_t *)rows->data)->count, 3);
  g_list_free_full(rows, dt_collection_list_row_free);
}

static void test_tree_rows(void **state)
{
  GList *rows = dt_collection_tree_rows(DT_COLLECTION_PROP_FOLDERS, "1=1");
  assert_int_equal(g_list_length(rows), 1);
  const dt_collection_list_row_t *r = rows->data;
  assert_string_equal(r->text, DT_TEST_IMAGES);
  assert_int_equal(r->count, 3);
  g_list_free_full(rows, dt_collection_list_row_free);
}

static void test_collected_rows(void **state)
{
  dt_collection_memory_update();
  const dt_imgid_t first = dt_collection_imgid_at_rowid(1);
  assert_true(dt_is_valid_imgid(first));
  assert_int_equal(dt_collection_rowid_of(first, -1), 1);
  // not in the collection: the caller's "none"
  assert_int_equal(dt_collection_rowid_of(999999, -1), -1);
  assert_int_equal(dt_collection_rowid_of(999999, NO_IMGID), NO_IMGID);
  assert_int_equal(dt_collection_imgid_at_rowid(999999), NO_IMGID);
}

static void test_selected_navigation(void **state)
{
  dt_collection_memory_update();
  dt_selection_set_folder_images(DT_TEST_IMAGES); // the three images, rows 1-3
  assert_int_equal(dt_collection_selected_rowid_first(), 1);
  assert_int_equal(dt_collection_selected_rowid_before(3, 1), 2);
  assert_int_equal(dt_collection_selected_rowid_before(1, 5), -1);
  assert_int_equal(dt_collection_selected_count_after(1), 2);
  assert_int_equal(dt_collection_selected_rowid_after(1, 1), 2);
  assert_int_equal(dt_collection_selected_rowid_after(3, 1), -1);
  assert_int_equal(dt_collection_count_after(1), 2);
}

int main(int argc, char *argv[])
{
  const struct CMUnitTest tests[] = {
    cmocka_unit_test(test_colorlabels),
    cmocka_unit_test(test_tags),
    cmocka_unit_test(test_metadata),
    cmocka_unit_test(test_list_rows),
    cmocka_unit_test(test_tree_rows),
    cmocka_unit_test(test_collected_rows),
    cmocka_unit_test(test_selected_navigation),
  };
  return cmocka_run_group_tests(tests, dt_test_catalog_setup, dt_test_catalog_teardown);
}
