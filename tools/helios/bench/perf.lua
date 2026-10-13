-- perf bench: time catalog operations on the synthetic collection built by
-- make_perf_library.py, from darktable's own Lua thread (--luacmd)
--
-- environment: HELIOS_PERF_OUT

local dt = require "darktable"
local out = assert(io.open(os.getenv("HELIOS_PERF_OUT"), "w"))

-- Lua has no wall clock below the second
local function now()
  local p = io.popen("date +%s.%N")
  local t = tonumber(p:read("*l"))
  p:close()
  return t
end

local function timed(name, fn)
  local t0 = now()
  local result = fn()
  out:write(string.format("%s\t%.3f\t%s\n", name, now() - t0, tostring(result)))
  out:flush()
end

local collect = dt.gui.libs.collect

local function set_collection(item, data)
  local rule = collect.new_rule()
  rule.mode = "DT_LIB_COLLECT_MODE_AND"
  rule.item = item
  rule.data = data
  collect.filter({ rule })
  return #dt.collection
end

local function scenario()
  timed("count database", function() return #dt.database end)
  -- right after a film roll collection, the next collection change takes
  -- about 2.5 s instead of 0.2 s in half of the runs, on darktable master too
  -- (darktable #3709): keep the film roll last so it does not skew the others
  timed("collection all", function() return set_collection("DT_COLLECTION_PROP_FILMROLL", "%") end)
  timed("collection tag", function() return set_collection("DT_COLLECTION_PROP_TAG", "helios|perf|tag-07") end)
  timed("collection all again", function() return set_collection("DT_COLLECTION_PROP_FILMROLL", "%") end)
  timed("collection color label", function() return set_collection("DT_COLLECTION_PROP_COLORLABEL", "red") end)
  timed("collection film roll", function()
    return set_collection("DT_COLLECTION_PROP_FILMROLL", "/helios-perf/film-050") end)
  -- the change that spikes (darktable #3741), timed on its own line
  timed("collection after film roll", function() return set_collection("DT_COLLECTION_PROP_FILMROLL", "%") end)

  -- the first 200 images, in id order. Each Lua write reloads the whole
  -- collection query (lua/image.c rating_member and friends), ~40 ms at
  -- 100,000 images, and the GUI thread then replays the queued reloads for
  -- minutes, so the batch stays small
  local batch = {}
  for i = 1, 200 do batch[i] = dt.database[i] end

  timed("select 200", function() dt.gui.selection(batch); return #dt.gui.selection() end)
  timed("rate 200", function()
    for i, img in ipairs(batch) do img.rating = i % 6 end
    return #batch end)
  timed("label 200", function()
    for _, img in ipairs(batch) do img.green = not img.green end
    return #batch end)
  local tag = dt.tags.create("helios|perf|bench")
  timed("tag 200", function()
    for _, img in ipairs(batch) do dt.tags.attach(tag, img) end
    return #dt.tags.get_tagged_images(tag) end)
  timed("untag 200", function()
    for _, img in ipairs(batch) do dt.tags.detach(tag, img) end
    return #dt.tags.get_tagged_images(tag) end)
  timed("title 200", function()
    for i, img in ipairs(batch) do img.title = "perf " .. (i % 100) end
    return #batch end)
end

local ok, err = xpcall(scenario, debug.traceback)
out:write(ok and "PERF OK\n" or ("PERF FAILED\t" .. tostring(err) .. "\n"))
out:close()
