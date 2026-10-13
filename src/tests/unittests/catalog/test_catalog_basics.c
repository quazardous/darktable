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
#include "common/image.h"
#include "common/iop_order.h"
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

static void test_numeric_counts(void **state)
{
  // every image (the three the fixture imports), per numeric property
  for(dt_collection_numeric_t prop = DT_COLLECTION_NUMERIC_APERTURE;
      prop <= DT_COLLECTION_NUMERIC_ASPECT_RATIO; prop++)
  {
    GList *counts = dt_collection_numeric_counts(prop, "1=1");
    int total = 0;
    for(GList *l = counts; l; l = g_list_next(l))
      total += ((dt_collection_count_t *)l->data)->count;
    assert_int_equal(total, 3);
    g_list_free_full(counts, g_free);

    double min = -1000.0, max = -1000.0;
    assert_true(dt_collection_numeric_range(prop, &min, &max));
    assert_true(min <= max);
  }

  // values come rounded as the filter shows them: ISO to whole numbers
  GList *iso = dt_collection_numeric_counts(DT_COLLECTION_NUMERIC_ISO, "1=1");
  for(GList *l = iso; l; l = g_list_next(l))
  {
    const double v = ((dt_collection_count_t *)l->data)->value;
    assert_true(v == (double)(long)v);
  }
  g_list_free_full(iso, g_free);

  // a rule nothing matches gives no counts
  assert_null(dt_collection_numeric_counts(DT_COLLECTION_NUMERIC_ISO, "mi.id < 0"));
}

static void test_flag_counts(void **state)
{
  int ratings[7], lcp[2];
  dt_collection_rating_counts("1=1", ratings);
  int total = 0;
  for(int i = 0; i < 7; i++) total += ratings[i];
  assert_int_equal(total, 3);

  // the fixture's images have no local copy
  dt_collection_local_copy_counts("1=1", lcp);
  assert_int_equal(lcp[0], 0);
  assert_int_equal(lcp[1], 3);

  // nothing matches: all zero, not left over from the previous call
  dt_collection_rating_counts("mi.id < 0", ratings);
  for(int i = 0; i < 7; i++) assert_int_equal(ratings[i], 0);
}

static void test_date_counts(void **state)
{
  // every imported image has an import timestamp
  GList *counts = dt_collection_date_counts(DT_COLLECTION_PROP_IMPORT_TIMESTAMP, "1=1");
  int total = 0;
  for(GList *l = counts; l; l = g_list_next(l))
  {
    const dt_collection_date_count_t *c = l->data;
    assert_true(c->value > 0);
    total += c->count;
  }
  assert_int_equal(total, 3);
  g_list_free_full(counts, g_free);

  int64_t min = 0, max = 0;
  assert_true(dt_collection_date_range(DT_COLLECTION_PROP_IMPORT_TIMESTAMP, &min, &max));
  assert_true(min > 0 && min <= max);

  assert_null(dt_collection_date_counts(DT_COLLECTION_PROP_IMPORT_TIMESTAMP, "mi.id < 0"));
}

static void test_filename_counts(void **state)
{
  // mire1.cr2, hlrecovery.arw, bayer4.crw
  GList *names = dt_collection_filename_counts("1=1");
  assert_int_equal(g_list_length(names), 3);
  gboolean mire = FALSE;
  for(GList *l = names; l; l = g_list_next(l))
  {
    const dt_collection_text_count_t *c = l->data;
    assert_int_equal(c->count, 1);
    if(!g_strcmp0(c->text, "mire1")) mire = TRUE;
  }
  assert_true(mire);
  g_list_free_full(names, dt_collection_text_count_free);

  GList *exts = dt_collection_extension_counts("1=1");
  assert_int_equal(g_list_length(exts), 3);
  for(GList *l = exts; l; l = g_list_next(l))
  {
    const dt_collection_text_count_t *c = l->data;
    assert_true(c->text[0] == '.' && g_ascii_isupper(c->text[1]));
    assert_true(c->flags & DT_IMAGE_RAW);
  }
  g_list_free_full(exts, dt_collection_text_count_free);
}

static void test_misc_counts(void **state)
{
  // each of the three images has a camera and dimensions
  const dt_collection_properties_t props[] = { DT_COLLECTION_PROP_CAMERA, DT_COLLECTION_PROP_DIMENSIONS };
  for(int i = 0; i < 2; i++)
  {
    GList *counts = dt_collection_misc_counts(props[i], "1=1");
    int total = 0;
    for(GList *l = counts; l; l = g_list_next(l)) total += ((dt_collection_text_count_t *)l->data)->count;
    assert_int_equal(total, 3);
    g_list_free_full(counts, dt_collection_text_count_free);
  }
  // no group holds more than one image
  assert_null(dt_collection_misc_counts(DT_COLLECTION_PROP_GROUP_ID, "1=1"));
  // not a misc property
  assert_null(dt_collection_misc_counts(DT_COLLECTION_PROP_TAG, "1=1"));
}

static void test_history_state_counts(void **state)
{
  int hist[3];
  dt_collection_history_counts("1=1", hist);
  assert_int_equal(hist[0] + hist[1] + hist[2], 3);

  int orders[DT_IOP_ORDER_LAST + 1];
  dt_collection_module_order_counts("1=1", orders);
  int total = 0;
  for(int i = 0; i <= DT_IOP_ORDER_LAST; i++) total += orders[i];
  assert_int_equal(total, 3);
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

  // the three test images share one folder, so one film roll
  GList *rolls = dt_collection_film_ids();
  assert_int_equal(g_list_length(rolls), 1);
  assert_true(GPOINTER_TO_INT(rolls->data) > 0);
  g_list_free(rolls);

  // the timeline's capture dates: every image is collected, so both
  // bounds agree and every dated row carries its id, in date order
  GTimeSpan min = 0, max = 0, cmin = 0, cmax = 0;
  dt_collection_capture_bounds(FALSE, &min, &max);
  dt_collection_capture_bounds(TRUE, &cmin, &cmax);
  assert_true(min <= max);
  assert_true(cmin == min && cmax == max);
  GArray *rows = dt_collection_capture_rows_after(0);
  for(guint i = 0; i < rows->len; i++)
  {
    const dt_collection_capture_row_t *r = &g_array_index(rows, dt_collection_capture_row_t, i);
    assert_true(dt_is_valid_imgid(r->imgid));
    if(i) assert_true(g_array_index(rows, dt_collection_capture_row_t, i - 1).datetime <= r->datetime);
  }
  if(rows->len) assert_true(g_array_index(rows, dt_collection_capture_row_t, rows->len - 1).datetime == max);
  g_array_free(rows, TRUE);
  rows = dt_collection_capture_rows_after(max);
  assert_int_equal(rows->len, 0);
  g_array_free(rows, TRUE);

  // the map: points over the whole world are the geotagged collected images
  double lat0 = 0.0, lat1 = 0.0, lon0 = 0.0, lon1 = 0.0;
  const int geotagged = dt_collection_geo_bounds(FALSE, &lat0, &lat1, &lon0, &lon1);
  GArray *points = dt_collection_geo_points(TRUE, -180.0, 180.0, 90.0, -90.0);
  assert_int_equal(points->len, geotagged);
  g_array_free(points, TRUE);
  points = dt_collection_geo_points(FALSE, -180.0, 180.0, 90.0, -90.0);
  assert_int_equal(points->len, geotagged);
  g_array_free(points, TRUE);
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

  assert_int_equal(dt_collection_selected_count(), 3);
  assert_true(dt_collection_is_selected(dt_collection_imgid_at_rowid(2)));
  assert_false(dt_collection_is_selected(999999));
  int min = 0, max = 0;
  assert_true(dt_collection_selected_rowid_range(&min, &max));
  assert_int_equal(min, 1);
  assert_int_equal(max, 3);

  assert_int_equal(dt_collection_neighbor_imgid(1, TRUE, FALSE), dt_collection_imgid_at_rowid(2));
  assert_int_equal(dt_collection_neighbor_imgid(3, FALSE, TRUE), dt_collection_imgid_at_rowid(2));
  assert_int_equal(dt_collection_neighbor_imgid(1, FALSE, FALSE), NO_IMGID);
  assert_int_equal(dt_collection_neighbor_imgid(3, TRUE, TRUE), NO_IMGID);

  // the culling rows from row 1: the three images, in row order, selected
  GList *rows = dt_collection_culling_rows(1, 3, FALSE);
  assert_int_equal(g_list_length(rows), 3);
  int expect = 1;
  for(GList *l = rows; l; l = g_list_next(l), expect++)
  {
    const dt_collection_culling_row_t *r = l->data;
    assert_int_equal(r->rowid, expect);
    assert_true(r->selected);
  }
  g_list_free_full(rows, g_free);
  // selection only, from the last row: completed with the earlier ones
  rows = dt_collection_culling_rows(3, 3, TRUE);
  assert_int_equal(g_list_length(rows), 3);
  g_list_free_full(rows, g_free);

  assert_int_equal(dt_collection_max_rowid(), 3);
  const dt_imgid_t second = dt_collection_imgid_at_rowid(2);
  assert_int_equal(dt_collection_selected_imgid_after(second), second);
  assert_int_equal(dt_collection_selected_imgid_before(dt_collection_imgid_at_rowid(1)), NO_IMGID);

  // the thumbtable's loads: before row 3, nearest first; after row 1, in
  // order; from row 2 on
  rows = dt_collection_thumb_rows_before(3, 5);
  assert_int_equal(g_list_length(rows), 2);
  assert_int_equal(((dt_collection_culling_row_t *)rows->data)->rowid, 2);
  assert_true(((dt_collection_culling_row_t *)rows->data)->selected);
  g_list_free_full(rows, g_free);
  rows = dt_collection_thumb_rows_after(1, 1);
  assert_int_equal(g_list_length(rows), 1);
  assert_int_equal(((dt_collection_culling_row_t *)rows->data)->rowid, 2);
  g_list_free_full(rows, g_free);
  // darkroom's ends of the collection
  int edge_rowid = 0;
  assert_int_equal(dt_collection_edge_imgid(FALSE, &edge_rowid), dt_collection_imgid_at_rowid(1));
  assert_int_equal(edge_rowid, 1);
  assert_int_equal(dt_collection_edge_imgid(TRUE, &edge_rowid), dt_collection_imgid_at_rowid(3));
  assert_int_equal(edge_rowid, 3);
  rows = dt_collection_thumb_rows_from(2, 5);
  assert_int_equal(g_list_length(rows), 2);
  assert_int_equal(((dt_collection_culling_row_t *)rows->data)->rowid, 2);
  assert_int_equal(((dt_collection_culling_row_t *)g_list_last(rows)->data)->rowid, 3);
  g_list_free_full(rows, g_free);

  // the view manager's selection bit, without the collection
  assert_true(dt_selection_contains(second));
  dt_selection_set_member(second, FALSE);
  assert_false(dt_selection_contains(second));
  dt_selection_set_member(second, FALSE);
  assert_false(dt_selection_contains(second));
  dt_selection_set_member(second, TRUE);
  dt_selection_set_member(second, TRUE);
  assert_true(dt_selection_contains(second));
  assert_int_equal(dt_collection_selected_count(), 3);
}

// last in the list: it adds a duplicate, which the totals above do not expect
static void test_duplicate_counts(void **state)
{
  int dups[2];
  dt_collection_duplicate_counts("1=1", dups);
  assert_int_equal(dups[0], 0);
  assert_int_equal(dups[1], 0);

  const dt_imgid_t cr2 = dt_test_catalog_image("mire1.cr2");
  const dt_imgid_t dup = dt_image_duplicate(cr2);
  assert_true(dt_is_valid_imgid(dup));
  dt_collection_duplicate_counts("1=1", dups);
  assert_int_equal(dups[0], 1);
  assert_int_equal(dups[1], 1);
}

int main(int argc, char *argv[])
{
  const struct CMUnitTest tests[] = {
    cmocka_unit_test(test_colorlabels),
    cmocka_unit_test(test_tags),
    cmocka_unit_test(test_metadata),
    cmocka_unit_test(test_numeric_counts),
    cmocka_unit_test(test_flag_counts),
    cmocka_unit_test(test_date_counts),
    cmocka_unit_test(test_filename_counts),
    cmocka_unit_test(test_misc_counts),
    cmocka_unit_test(test_history_state_counts),
    cmocka_unit_test(test_list_rows),
    cmocka_unit_test(test_tree_rows),
    cmocka_unit_test(test_collected_rows),
    cmocka_unit_test(test_selected_navigation),
    cmocka_unit_test(test_duplicate_counts),
  };
  return cmocka_run_group_tests(tests, dt_test_catalog_setup, dt_test_catalog_teardown);
}
