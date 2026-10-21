-- equivalence bench scenario: drives the catalog through the Lua API and
-- records every read result, so that both writes (database dump, sidecars)
-- and reads (the output file) can be compared across builds.
--
-- run by run.sh as darktable --luacmd, inside darktable's own Lua thread:
-- loading darktable as a library from a standalone interpreter races with
-- darktable's async Lua threads (lua/init.c load_from_lua, lua/call.c).
--
-- environment: HELIOS_BENCH_IMAGES, HELIOS_BENCH_INTEG, HELIOS_BENCH_OUT

local dt = require "darktable"
local images = os.getenv("HELIOS_BENCH_IMAGES")
local integ = os.getenv("HELIOS_BENCH_INTEG")
local outfile = assert(io.open(os.getenv("HELIOS_BENCH_OUT"), "w"))

local function out(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
  outfile:write(table.concat(t, "\t"), "\n")
end

local function basename(img)
  return img.filename .. "#" .. img.duplicate_index
end

local function sorted_images()
  local list = {}
  for _, img in ipairs(dt.database) do list[#list + 1] = img end
  table.sort(list, function(a, b)
    if a.filename ~= b.filename then return a.filename < b.filename end
    return a.duplicate_index < b.duplicate_index
  end)
  return list
end

local function tag_names(img)
  local names = {}
  for _, tag in ipairs(dt.tags.get_tags(img)) do names[#names + 1] = tag.name end
  table.sort(names)
  return table.concat(names, ",")
end

-- the lighttable keeps drawing thumbnails even with an empty collection,
-- and a missing one is built from the raw by a background job that writes
-- back an image struct copied before decoding (common/mipmap_cache.c,
-- DT_MIPMAP_FULL), undoing ratings set meanwhile. Building the thumbnails
-- here, synchronously, leaves that job nothing to load from the raw.
local function settle()
  -- HELIOS_BENCH_RACY=1 keeps the race, to check a darktable fix for it
  if os.getenv("HELIOS_BENCH_RACY") then return end
  for _, img in ipairs(dt.database) do img:generate_cache(true, 1, 1) end
end

local function dump_state(step)
  settle()
  out("== " .. step)
  for _, img in ipairs(sorted_images()) do
    out(basename(img), "rating=" .. img.rating,
        "labels=" .. (img.red and "r" or "") .. (img.yellow and "y" or "")
          .. (img.green and "g" or "") .. (img.blue and "b" or "")
          .. (img.purple and "p" or ""),
        "title=" .. tostring(img.title), "creator=" .. tostring(img.creator),
        "notes=" .. tostring(img.notes),
        "lat=" .. tostring(img.latitude), "lon=" .. tostring(img.longitude),
        "altered=" .. tostring(img.is_altered),
        "group=" .. basename(img.group_leader),
        "tags=" .. tag_names(img))
  end
  local styles = {}
  for _, s in ipairs(dt.styles) do
    -- skip the camera styles shipped with darktable
    if s.name:match("^helios") then
      styles[#styles + 1] = s.name .. ":" .. tostring(s.description)
    end
  end
  table.sort(styles)
  out("styles", table.concat(styles, ","))
  out("films", #dt.films, "images", #dt.database)
end

local function find(name, dup)
  dup = dup or 0
  for _, img in ipairs(dt.database) do
    if img.filename == name and img.duplicate_index == dup then return img end
  end
  error("image not found: " .. name .. "#" .. dup)
end

local function find_style(name)
  for _, s in ipairs(dt.styles) do
    if s.name == name then return s end
  end
  error("style not found: " .. name)
end

local function scenario()
  -- 1. import, file by file: importing a directory runs as a background job
  -- that the scenario would have to wait for
  local files = {}
  for f in io.popen('ls "' .. images .. '"'):lines() do
    if not f:match("%.xmp$") then files[#files + 1] = f end
  end
  table.sort(files)
  for _, f in ipairs(files) do dt.database.import(images .. "/" .. f) end
  dump_state("import")

  -- film rolls and database indexing
  local film = dt.films[1]
  out("film 1 path", film.path == images and "images dir" or film.path, "tostring", tostring(film) == images)
  out("film 1 length", #film, "first", basename(film[1]), "beyond", tostring(film[#film + 1]))
  out("films beyond", tostring(dt.films[#dt.films + 1]))
  out("database 1", basename(dt.database[1]), "beyond", tostring(dt.database[#dt.database + 1]))
  out("get_image", basename(dt.database.get_image(dt.database[2].id)), "missing", tostring(dt.database.get_image(999999)))

  local cr2 = find("mire1.cr2")
  local arw = find("hlrecovery.arw")
  local raf = find("mire1-xtrans.raf")
  local raf4 = find("xtransIV.raf")
  local crw = find("bayer4.crw")

  -- history from the integration tests' sidecars. Applying a sidecar
  -- replaces rating, labels, tags and metadata too, so it comes first.
  cr2:apply_sidecar(integ .. "/0001-exposure/exposure.xmp")
  arw:apply_sidecar(integ .. "/0035-multiple-modules/multiple-modules.xmp")
  dump_state("sidecars")

  -- 2. ratings and reject
  cr2.rating = 5
  arw.rating = 3
  raf.rating = -1
  raf4.rating = 1
  raf4.rating = 0
  dump_state("ratings")

  -- 3. color labels
  cr2.red = true
  cr2.blue = true
  arw.green = true
  crw.purple = true
  cr2.blue = false
  dump_state("labels")

  -- 4. tags
  local t_a = dt.tags.create("helios|bench|a")
  local t_b = dt.tags.create("helios|bench|b")
  local t_c = dt.tags.create("helios|other")
  dt.tags.attach(t_a, cr2)
  dt.tags.attach(t_a, arw)
  dt.tags.attach(t_b, arw)
  dt.tags.attach(t_c, raf4)
  dt.tags.detach(t_a, arw)
  t_c:delete()
  local tagged = {}
  for _, img in ipairs(dt.tags.get_tagged_images(t_a)) do tagged[#tagged + 1] = basename(img) end
  table.sort(tagged)
  out("tagged helios|bench|a", table.concat(tagged, ","))
  local found = dt.tags.find("helios|bench|b")
  out("find helios|bench|b", found and found.name or "nil")
  out("length helios|bench|b", #t_b)
  out("index helios|bench|b 1", t_b[1] and basename(t_b[1]) or "nil")
  out("index helios|bench|b 9", tostring(t_b[9]))
  out("tags count", #dt.tags)
  out("tags 1", dt.tags[1] and dt.tags[1].name or "nil")
  out("tags last", dt.tags[#dt.tags] and dt.tags[#dt.tags].name or "nil")
  dump_state("tags")

  -- 5. metadata and geolocation
  cr2.title = "bench title"
  cr2.creator = "helios"
  cr2.notes = "first note"
  arw.title = "other"
  arw.title = ""
  crw.latitude = 45.5
  crw.longitude = 6.25
  dump_state("metadata")

  -- 6. styles
  dt.styles.create(cr2, "helios-bench-exposure", "from exposure test")
  local style = find_style("helios-bench-exposure")
  dt.styles.apply(style, raf4)
  -- duplicate() returns nothing (lua/styles.c style_duplicate)
  style:duplicate("helios-bench-copy", "copied")
  style:duplicate("helios-bench-kept")
  find_style("helios-bench-copy"):delete()
  out("styles count", #dt.styles)
  out("styles 1", dt.styles[1] and dt.styles[1].name or "nil")
  out("styles last", dt.styles[#dt.styles] and dt.styles[#dt.styles].name or "nil")
  crw:reset()
  dump_state("history and styles")

  -- 7. duplicates, groups, deletion
  local dup1 = cr2:duplicate()
  local dup2 = cr2:duplicate_with_history()
  settle()
  dup2.rating = 2
  dup1:group_with(cr2)
  dup2:group_with(cr2)
  local members = {}
  for _, img in ipairs(cr2:get_group_members()) do members[#members + 1] = basename(img) end
  table.sort(members)
  out("group members", table.concat(members, ","), "leader", basename(cr2:get_group_members().leader))
  raf:delete()
  dump_state("duplicates")
end

local ok, err = xpcall(scenario, debug.traceback)
if not ok then out("SCENARIO FAILED", err) end
out(ok and "SCENARIO OK" or "SCENARIO ABORTED")
outfile:close()

