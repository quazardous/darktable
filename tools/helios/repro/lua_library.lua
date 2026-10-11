-- load darktable as a library from a standalone lua interpreter, change
-- ratings and labels, and check that the last values stick
--
-- usage: lua lua_library.lua <prefix> <configdir> <images dir> <out file>

local prefix, configdir, images, outpath = ...
local dt = require("darktable")(
  "--library", ":memory:", "--configdir", configdir,
  "--moduledir", prefix .. "/lib64/darktable",
  "--datadir", prefix .. "/share/darktable",
  "--disable-opencl", "--conf", "ui/show_welcome_screen=false")

local out = assert(io.open(outpath, "w"))
local files = { "bayer4.crw", "hlrecovery.arw", "mire1.cr2", "mire1-xtrans.raf", "xtransIV.raf" }
local imgs = {}
for _, f in ipairs(files) do imgs[#imgs + 1] = dt.database.import(images .. "/" .. f) end
out:write("imported ", #imgs, "\n")

local rounds = 50
for round = 1, rounds do
  for i, img in ipairs(imgs) do
    img.rating = (round + i) % 6
    img.red = round % 2 == 0
  end
end

local wrong = 0
for i, img in ipairs(imgs) do
  local rating, red = (rounds + i) % 6, rounds % 2 == 0
  if img.rating ~= rating or img.red ~= red then
    wrong = wrong + 1
    out:write("WRONG ", img.filename, " rating=", img.rating, " red=", tostring(img.red), "\n")
  end
end
out:write(wrong == 0 and "DONE OK\n" or "DONE WRONG\n")
out:close()
