local Common = {}

-- Сериализация таблицы в Lua Table Literal
function Common.serializeTable(val)
    local t = type(val)
    if t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        for k, v in pairs(val) do
            local keyStr = (type(k) == "string" and k:match("^[%a_][%w_]*$"))
                and k
                or "[" .. Common.serializeTable(k) .. "]"
            table.insert(parts, keyStr .. " = " .. Common.serializeTable(v))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return "nil"
end

-- Десериализация строки Lua Table Literal обратно в таблицу (совместимо с Lua 5.1-5.4)
function Common.deserializeTable(str)
    if type(str) ~= "string" or str == "" then
        return nil
    end
    local code = str
    if not code:match("^%s*return%s") then
        code = "return " .. code
    end

    local fn
    local loadstring_fn = rawget(_G, "loadstring")
    if loadstring_fn then
        -- Lua 5.1 (Lightroom Classic runtime) / LuaJIT
        fn = loadstring_fn(code)
        local set_env = rawget(_G, "setfenv")
        if fn and set_env then
            set_env(fn, {})
        end
    elseif type(load) == "function" then
        -- Lua 5.2, 5.3, 5.4 (режим "t" - только текст, env = {} для песочницы)
---@diagnostic disable-next-line: redundant-parameter
        fn = load(code, "=(data)", "t", {})
    end

    if fn then
        local ok, res = pcall(fn)
        if ok and type(res) == "table" then
            return res
        end
    end
    return nil
end

return Common
