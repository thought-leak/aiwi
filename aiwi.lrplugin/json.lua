-- JSON сериализация / десериализация (без внешних зависимостей)
local Json = {}

-- --------------------------------------------------------------------------
-- Кодирование
-- --------------------------------------------------------------------------

local function escapeJsonString(val)
    local s = tostring(val)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\b', '\\b')
    s = s:gsub('\f', '\\f')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return '"' .. s .. '"'
end

local function isArray(t)
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then return false end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return count > 0
end

local encodeJsonValue

local function encodeJsonArray(val)
    local parts = {}
    for i = 1, #val do
        parts[i] = encodeJsonValue(val[i])
    end
    return "[" .. table.concat(parts, ", ") .. "]"
end

local function encodeJsonObject(val)
    local parts = {}
    for k, v in pairs(val) do
        table.insert(parts, escapeJsonString(tostring(k)) .. ": " .. encodeJsonValue(v))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

encodeJsonValue = function(val)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then
            return "null"
        end
        return tostring(val)
    elseif t == "string" then
        return escapeJsonString(val)
    elseif t == "table" then
        if isArray(val) then
            return encodeJsonArray(val)
        else
            return encodeJsonObject(val)
        end
    else
        return "null"
    end
end

-- Кодирует Lua-значение (nil/boolean/number/string/table) в JSON-строку
function Json.encode(val)
    return encodeJsonValue(val)
end

-- --------------------------------------------------------------------------
-- Декодирование
-- --------------------------------------------------------------------------

local function skipWhitespace(str, pos)
    local sub = str:sub(pos)
    local _, next_pos = sub:find("^[ \t\r\n]+")
    if next_pos then
        return pos + next_pos
    end
    return pos
end

local parseJsonValue

local function parseJsonString(str, pos)
    local i = pos + 1
    local len = #str
    local buf = {}

    while i <= len do
        local c = str:sub(i, i)
        if c == '"' then
            return table.concat(buf), i + 1
        elseif c == '\\' then
            i = i + 1
            if i > len then error("Unfinished escape sequence in string at " .. i) end
            local esc = str:sub(i, i)
            if esc == '"' or esc == '\\' or esc == '/' then
                table.insert(buf, esc)
            elseif esc == 'b' then
                table.insert(buf, "\b")
            elseif esc == 'f' then
                table.insert(buf, "\f")
            elseif esc == 'n' then
                table.insert(buf, "\n")
            elseif esc == 'r' then
                table.insert(buf, "\r")
            elseif esc == 't' then
                table.insert(buf, "\t")
            elseif esc == 'u' then
                local hex = str:sub(i + 1, i + 4)
                if #hex < 4 then error("Invalid unicode escape at " .. i) end
                local code = tonumber(hex, 16)
                if not code then error("Invalid unicode escape at " .. i) end
                if code < 128 then
                    table.insert(buf, string.char(code))
                elseif code < 2048 then
                    table.insert(buf, string.char(192 + math.floor(code / 64), 128 + (code % 64)))
                else
                    table.insert(buf, string.char(
                        224 + math.floor(code / 4096),
                        128 + (math.floor(code / 64) % 64),
                        128 + (code % 64)
                    ))
                end
                i = i + 4
            else
                table.insert(buf, esc)
            end
        else
            table.insert(buf, c)
        end
        i = i + 1
    end
    error("Unterminated string starting at " .. pos)
end

local function parseJsonNumber(str, pos)
    local sub = str:sub(pos)
    local s, e = sub:find("^-?%d+%.?%d*[eE]?[+-]?%d*")
    if not s then
        error("Invalid number at " .. pos)
    end
    local num = tonumber(sub:sub(s, e))
    if not num then
        error("Invalid number at " .. pos)
    end
    return num, pos + e
end

local function parseJsonArray(str, pos)
    local arr = {}
    pos = skipWhitespace(str, pos + 1)
    if str:sub(pos, pos) == ']' then
        return arr, pos + 1
    end

    while true do
        local val
        val, pos = parseJsonValue(str, pos)
        table.insert(arr, val)

        pos = skipWhitespace(str, pos)
        local c = str:sub(pos, pos)
        if c == ']' then
            return arr, pos + 1
        elseif c == ',' then
            pos = skipWhitespace(str, pos + 1)
        else
            error("Expected ',' or ']' in array at " .. pos)
        end
    end
end

local function parseJsonObject(str, pos)
    local obj = {}
    pos = skipWhitespace(str, pos + 1)
    if str:sub(pos, pos) == '}' then
        return obj, pos + 1
    end

    while true do
        if str:sub(pos, pos) ~= '"' then
            error("Expected string key in object at " .. pos)
        end
        local key
        key, pos = parseJsonString(str, pos)

        pos = skipWhitespace(str, pos)
        if str:sub(pos, pos) ~= ':' then
            error("Expected ':' after key in object at " .. pos)
        end
        pos = skipWhitespace(str, pos + 1)

        local val
        val, pos = parseJsonValue(str, pos)
        obj[key] = val

        pos = skipWhitespace(str, pos)
        local c = str:sub(pos, pos)
        if c == '}' then
            return obj, pos + 1
        elseif c == ',' then
            pos = skipWhitespace(str, pos + 1)
        else
            error("Expected ',' or '}' in object at " .. pos)
        end
    end
end

parseJsonValue = function(str, pos)
    pos = skipWhitespace(str, pos)
    local c = str:sub(pos, pos)

    if c == '"' then
        return parseJsonString(str, pos)
    elseif c == '{' then
        return parseJsonObject(str, pos)
    elseif c == '[' then
        return parseJsonArray(str, pos)
    elseif c == 't' and str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif c == 'f' and str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif c == 'n' and str:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    elseif c == '-' or (c >= '0' and c <= '9') then
        return parseJsonNumber(str, pos)
    else
        error("Unexpected character '" .. c .. "' at position " .. pos)
    end
end

-- Декодирует JSON-строку в Lua-значение.
-- Возвращает nil, если строка пуста или разобрать её не удалось.
function Json.decode(str)
    if type(str) ~= "string" or str == "" then
        return nil
    end
    local ok, res = pcall(parseJsonValue, str, 1)
    if ok then
        return res
    end
    return nil
end

return Json
