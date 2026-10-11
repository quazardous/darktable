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

#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <cmocka.h>

#include <glib/gstdio.h>

#include "common/darktable.h"
#include "win/main_wrapper.h"

// --threads must still hold when dt_init() returns: per-thread buffers are
// sized by dt_get_num_threads(), and a pipe running on the calling thread
// (darktable-cli) uses the OpenMP thread count of that thread. -t 1 differs
// from the core count on any multi-core machine
static void test_threads_option_survives_init(void **state)
{
#ifndef _OPENMP
  skip();
#else
  if(omp_get_num_procs() < 2) skip();

  gchar *tmpdir = g_dir_make_tmp("dt-openmp-test-XXXXXX", NULL);
  assert_non_null(tmpdir);
  char *argv[] = { "darktable-test",
                   "--library", ":memory:",
                   "--configdir", tmpdir,
                   "--cachedir", tmpdir,
                   "--datadir", DT_TEST_DATADIR,
                   "--moduledir", DT_TEST_MODULEDIR,
                   "--disable-opencl",
                   "-t", "1",
                   NULL };
  const int argc = sizeof(argv) / sizeof(argv[0]) - 1;
  assert_int_equal(dt_init(argc, argv, FALSE, FALSE, NULL), 0);

  assert_int_equal(darktable.num_openmp_threads, 1);
  assert_int_equal(dt_get_num_threads(), 1);
  assert_int_equal(omp_get_max_threads(), 1);

  dt_cleanup();
  gchar *cmd = g_strdup_printf("rm -rf '%s'", tmpdir);
  assert_int_equal(system(cmd), 0);
  g_free(cmd);
  g_free(tmpdir);
#endif
}

int main(int argc, char *argv[])
{
  const struct CMUnitTest tests[] = {
    cmocka_unit_test(test_threads_option_survives_init),
  };
  return cmocka_run_group_tests(tests, NULL, NULL);
}
// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
