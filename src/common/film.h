/*
    This file is part of darktable,
    Copyright (C) 2009-2020 darktable developers.

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

#pragma once

#include "common/darktable.h"
#include "common/dtpthread.h"

#include <glib.h>
#include <inttypes.h>

/**
 * film roll.
 * this is one directory of images on disk.
 * also manages the preview image cache.
 */
typedef struct dt_film_t
{
  dt_filmid_t id;
  char dirname[512];
  dt_pthread_mutex_t images_mutex;
  GDir *dir;
  int32_t num_images, last_loaded;
  int32_t ref;
} dt_film_t;

void dt_film_init(dt_film_t *film);
void dt_film_cleanup(dt_film_t *film);
/** open film with given id. */
gboolean dt_film_open(const dt_filmid_t id);

/** open num-th most recently used film. */
// gboolean dt_film_open_recent(const int32_t num);
/** import new film and all images in this directory as a background task(non-recursive, existing films/images
 * are respected). */
dt_filmid_t dt_film_import(const char *dirname);
/** constructs the lighttable/query setting for this film, respecting stars and filters. */
void dt_film_set_query(const dt_filmid_t id);
/** get id associated with filmroll */
dt_filmid_t dt_film_get_id(const char *folder);
/** a film roll whose folder matches with SQL LIKE (ASCII case ignored, % and
    _ in folder act as wildcards), as the collect module's folder tree
    compares; NO_FILMID when none. dt_film_get_id() compares exactly */
dt_filmid_t dt_film_get_id_like(const char *folder);
/** removes this film and all its images from db. */
void dt_film_remove(const dt_filmid_t id);
/** checks if film is empty */
gboolean dt_film_is_empty(const dt_filmid_t id);
/** folder of a film roll, or NULL if it does not exist; free with g_free() */
gchar *dt_film_get_folder(const dt_filmid_t id);
/** number of images in a film roll */
uint32_t dt_film_count_images(const dt_filmid_t id);
/** n-th image (from 0, by id) of a film roll, or NO_IMGID */
dt_imgid_t dt_film_get_nth_image(const dt_filmid_t id, const int n);
/** number of film rolls */
uint32_t dt_film_count(void);
/** n-th film roll id (from 0, by id), or NO_FILMID */
dt_filmid_t dt_film_get_nth(const int n);
/** all film roll ids, most recently opened first (never opened last) */
GList *dt_film_get_by_access(void);
/** ids of the images of a film roll */
GList *dt_film_get_images(const dt_filmid_t id);
/** Creating a new filmroll */
dt_filmid_t dt_film_new(dt_film_t *film, const char *directory);
/** removes all empty film rolls. */
void dt_film_remove_empty();
/** gets all image ids in film. the returned GList has to be freed with g_list_free(). */
GList *dt_film_get_image_ids(const dt_filmid_t filmid);
// initialize film folder status
void dt_film_set_folder_status();
/** TRUE when a film roll lives at the folder or below it, as a node of the
    folders tree exists */
gboolean dt_film_folder_exists(const char *folder);
/** the film roll folder closest to folder: the folder itself, else its
    nearest film roll ancestor, else its nearest film roll descendant.
    Newly allocated, NULL when there is none */
gchar *dt_film_folder_for(const char *folder);
/** move the film rolls at old_path and below it to new_path: a film roll
    at old_path becomes new_path, one below keeps its path under it */
void dt_film_relocate_folder(const char *old_path, const char *new_path);
// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on

