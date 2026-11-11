-- CompletionRoute :: tools/sv_to_json.lua
-- Read one CompletionRoute SavedVariables file and print a part of it as JSON on stdout (read-only).
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
--   luajit tools/sv_to_json.lua <path/to/SavedVariables/CompletionRoute.lua> [--key bugReports]
--
-- Prints {"<key>": CompletionRouteDB[key], "lastError": CompletionRouteDB.lastError}; a part that is not there is left out.
-- Used by tools/ingest_beta_reports.py.  The file is executed in an empty environment (no os, io or other globals),
-- under an instruction budget, and is never written.  Exit 2 = the file did not load.
package.path = "./?.lua;" .. package.path
local here = (arg[0] or ""):match("^(.*)[/\\]") or "."
local J = dofile(here .. "/json.lua")

local path, key = nil, "bugReports"
local i = 1
while i <= #arg do
    if arg[i] == "--key" then key = arg[i + 1] i = i + 1
    elseif not path then path = arg[i] end
    i = i + 1
end
if not path then io.stderr:write("usage: luajit tools/sv_to_json.lua <SavedVariables/CompletionRoute.lua> [--key bugReports]\n") os.exit(64) end

local fh = io.open(path, "rb")
if not fh then io.stderr:write("cannot open " .. path .. "\n") os.exit(2) end
local text = fh:read("*a")
fh:close()
if text:byte(1) == 27 then io.stderr:write("refusing precompiled chunk: " .. path .. "\n") os.exit(2) end

local env = {}
local fn, err = loadstring(text, "=" .. path)
if not fn then io.stderr:write("parse error: " .. tostring(err) .. "\n") os.exit(2) end
setfenv(fn, env)
-- a SavedVariables file is a handful of table constructors; anything that runs this long is not one
if jit and jit.off then jit.off(fn, true) end
debug.sethook(function() error("instruction budget exceeded", 2) end, "", 2e8)
local ok, rerr = pcall(fn)
debug.sethook()
if not ok then io.stderr:write("load error: " .. tostring(rerr) .. "\n") os.exit(2) end

local db = rawget(env, "CompletionRouteDB")
local out = {}
if type(db) == "table" then
    out[key] = db[key]
    out.lastError = db.lastError
end
io.write(J.encode(out))   -- a missing part is simply absent
io.write("\n")
