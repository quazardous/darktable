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

int main(int argc, char *argv[])
{
  const struct CMUnitTest tests[] = {
    cmocka_unit_test(test_colorlabels),
    cmocka_unit_test(test_tags),
    cmocka_unit_test(test_metadata),
    cmocka_unit_test(test_numeric_counts),
    cmocka_unit_test(test_flag_counts),
  };
  return cmocka_run_group_tests(tests, dt_test_catalog_setup, dt_test_catalog_teardown);
}
