-- CompletionRoute :: tools/json.lua
-- Small JSON encoder/decoder for the offline tools (tools/sv_to_json.lua, tools/vplayer_repro.lua, tests).  Plain Lua 5.1.
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Encoding: a table whose keys are exactly 1..n is an array, an empty table is [], anything else is an object with
-- string keys (numbers become "12").  NaN and infinities become null.  Keys are sorted so output is stable.
-- Decoding: objects and arrays become tables (null inside an array keeps its slot as nil; JSON.null marks it if wanted).
local J = {}
J.null = setmetatable({}, { __tostring = function() return "null" end })   -- decode marker for a JSON null

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function str(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or ("\\u%04x"):format(c:byte()) end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

local function enc(v, out, depth)
    local t = type(v)
    if depth > 64 then error("json: nesting too deep") end
    if t == "nil" or v == J.null then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
        elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = ("%d"):format(v)
        else out[#out + 1] = ("%.10g"):format(v) end
    elseif t == "string" then out[#out + 1] = str(v)
    elseif t == "table" then
        local arr, n = isArray(v)
        if arr then
            out[#out + 1] = "["
            for i = 1, n do
                if i > 1 then out[#out + 1] = "," end
                enc(v[i], out, depth + 1)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do
                local tk = type(k)
                if tk == "string" or tk == "number" then keys[#keys + 1] = k end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = str(tostring(k))
                out[#out + 1] = ":"
                enc(v[k], out, depth + 1)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"   -- functions, userdata: not data
    end
end

function J.encode(v)
    local out = {}
    enc(v, out, 0)
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Decoder
-- ---------------------------------------------------------------------------
local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

function J.decode(s)
    local pos = 1
    local function fail(msg) error(("json: %s at byte %d"):format(msg, pos), 0) end
    local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
    local value
    local function readString()
        pos = pos + 1   -- opening quote
        local buf = {}
        while true do
            local c = s:sub(pos, pos)
            if c == "" then fail("unterminated string") end
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[e] then buf[#buf + 1] = map[e] pos = pos + 2
                elseif e == "u" then
                    local hex = s:sub(pos + 2, pos + 5)
                    local cp = tonumber(hex, 16)
                    if not cp or #hex < 4 then fail("bad \\u escape") end
                    pos = pos + 6
                    if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
                        local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                            pos = pos + 6
                        end
                    end
                    buf[#buf + 1] = utf8char(cp)
                else fail("bad escape") end
            else
                local stop = s:find('["\\]', pos) or (#s + 1)
                buf[#buf + 1] = s:sub(pos, stop - 1)
                pos = stop
            end
        end
        return table.concat(buf)
    end
    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local t = {}
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
            while true do
                ws()
                if s:sub(pos, pos) ~= '"' then fail("expected key") end
                local k = readString()
                ws()
                if s:sub(pos, pos) ~= ":" then fail("expected ':'") end
                pos = pos + 1
                local v = value()
                if v ~= J.null then t[k] = v end
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return t end
                if d ~= "," then fail("expected ',' or '}'") end
            end
        elseif c == "[" then
            pos = pos + 1
            local t, n = {}, 0
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
            while true do
                local v = value()
                n = n + 1
                if v ~= J.null then t[n] = v end
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return t end
                if d ~= "," then fail("expected ',' or ']'") end
            end
        elseif c == '"' then return readString()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return J.null
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" then fail("unexpected '" .. c .. "'") end
            pos = pos + #num
            return tonumber(num) or fail("bad number")
        end
    end
    local v = value()
    ws()
    if pos <= #s then fail("trailing data") end
    if v == J.null then return nil end
    return v
end

return J
