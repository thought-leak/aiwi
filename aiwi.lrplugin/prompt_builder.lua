local MetadataHelper = require 'metadata_helper'

local PromptBuilder = {}

-- Удаляет ведущие и завершающие пробелы (в т.ч. табуляцию)
local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Разбирает содержимое подстановки на варианты и их части.
-- Одиночный "|" разделяет варианты; пары "{{", "}}" и "||" заменяются
-- на литералы "{", "}", "|"; одиночный "{" открывает ключевое слово,
-- закрываемое одиночной "}" (одиночной "}" без пары - литерал).
-- Возвращает массив вариантов (минимум один); вариант - массив частей
-- вида { kind = "text", text = ... } или { kind = "key", key = ... }
local function parseVariants(content)
    local variants = {}
    local variant = {}
    local text = {}
    local pos = 1
    local len = #content

    -- Сбрасывает накопленный текст в текущий вариант
    local function flushText()
        if #text > 0 then
            table.insert(variant, { kind = "text", text = table.concat(text) })
            text = {}
        end
    end

    -- Завершает текущий вариант
    local function flushVariant()
        flushText()
        table.insert(variants, variant)
        variant = {}
    end

    while pos <= len do
        local c = content:sub(pos, pos)
        local n = content:sub(pos + 1, pos + 1)

        if c == "{" and n == "{" then
            table.insert(text, "{")
            pos = pos + 2
        elseif c == "}" and n == "}" then
            table.insert(text, "}")
            pos = pos + 2
        elseif c == "|" and n == "|" then
            table.insert(text, "|")
            pos = pos + 2
        elseif c == "|" then
            -- Одиночный "|" - граница вариантов
            flushVariant()
            pos = pos + 1
        elseif c == "{" then
            -- Ключевое слово: до первой одиночной "}". Незакрытый
            -- "{" остаётся литеральным текстом
            local close = content:find("}", pos + 1, true)

            if close then
                flushText()
                table.insert(variant,
                    { kind = "key", key = content:sub(pos + 1, close - 1) })
                pos = close + 1
            else
                table.insert(text, c)
                pos = pos + 1
            end
        else
            table.insert(text, c)
            pos = pos + 1
        end
    end

    -- Последний вариант (в т.ч. пустой - при пустом содержимом
    -- подстановки это единственный вариант)
    flushVariant()

    return variants
end

-- Собирает значения метаданных photo по ключевым словам (частям
-- kind = "key") варианта. Возвращает таблицу значений {key = value}
-- или nil, если хотя бы одно значение пустое (или ключ пуст)
local function collectValues(variant, photo)
    local values = {}

    for _, part in ipairs(variant) do
        if part.kind == "key" then
            local key = trim(part.key)

            if key == "" then
                return nil
            end

            local value = MetadataHelper.GetFormattedMetadata(photo, key)
            value = value and trim(value) or ""

            if value == "" then
                return nil
            end

            values[key] = value
        end
    end

    return values
end

-- Собирает строку варианта: текстовые части (с литералами "{{", "}}",
-- "||" уже заменёнными на одиночные символы) - как есть, ключевые
-- слова - значениями метаданных
local function substitute(variant, values)
    local out = {}

    for _, part in ipairs(variant) do
        if part.kind == "key" then
            table.insert(out, values[trim(part.key)] or "")
        else
            table.insert(out, part.text)
        end
    end

    return table.concat(out)
end

-- Ищет закрывающую "%" подстановки, начиная с позиции from: пары
-- "%%" внутри подстановки - литеральный процент, границей не считаются.
-- Возвращает позицию закрывающей "%" или nil, если "%" не закрыта
local function findClosingPercent(s, from)
    local pos = from

    while true do
        local percent = s:find("%", pos, true)

        if not percent then
            return nil
        end

        if s:sub(percent + 1, percent + 1) == "%" then
            pos = percent + 2
        else
            return percent
        end
    end
end

-- Обрабатывает одну подстановку (содержимое между открывающей и
-- закрывающей "%"): последовательно перебирает варианты и возвращает
-- строку самого левого применимого варианта с подставленными
-- значениями метаданных. Если применимого варианта нет - пустая
-- строка (место подстановки вычищается)
local function buildSubstitution(content, photo)
    for _, variant in ipairs(parseVariants(content)) do
        local values = collectValues(variant, photo)

        if values then
            return substitute(variant, values)
        end
    end

    return ""
end

-- Подставляет в строку rawPrompt значения метаданных фотографии photo.
--
-- Двойной процент "%%" - литеральный знак процента: он НЕ открывает и
-- НЕ закрывает подстановку и заменяется на одинарный "%" - как в
-- основном тексте строки, так и внутри вариантов подстановки.
-- Одиночная "%" в тексте всегда граница подстановки: литеральный
-- процент вне подстановок пишется только парой "%%".
--
-- ВНУТРИ подстановки действуют литеральные пары (вне подстановок они
-- не обрабатываются): "{{" -> "{", "}}" -> "}", "||" -> "|" - при
-- этом одиночный "|" по-прежнему разделяет варианты, а одиночный "{"
-- открывает ключевое слово до одиночной "}". Благодаря этому можно
-- вывести в промпт литеральные фигурные скобки и вертикальные черты:
-- "%{{"город": "{city}"}}%" при city="Moscow" даёт {"город": "Moscow"},
-- а "%{{city}}%" даёт литеральное "{city}" без подстановки.
--
-- Места подстановки заключены в знак процента: "%текст%" - таких мест
-- может быть несколько. Подстановки ищутся последовательно слева
-- направо: одинарная "%" открывает, следующая одинарная "%" (не
-- входящая в пару "%%") закрывает. Если "%" осталась незакрытой, она
-- остаётся литеральной и сканирование продолжается дальше по строке.
--
-- Содержимое подстановки разбивается знаком "|" на варианты (может
-- быть и один). Применяется только один вариант - самый левый,
-- который может быть выполнен.
--
-- В варианте ключевые слова метаданных заключены в фигурные скобки:
-- "{city}", "{ stateProvince }" - пробелы по краям ключа отбрасываются.
-- Значения берутся через MetadataHelper.GetFormattedMetadata(photo,
-- key): строковые и числовые ключи getRawMetadata возвращаются сырыми
-- (число - в виде строки), прочие - через getFormattedMetadata.
-- Вариант может быть выполнен, если ВСЕ значения по ключевым словам
-- непустые (после обрезки пробелов). Вариант без ключевых слов
-- выполняется всегда. Ключевые слова заменяются значениями, полученная
-- строка вписывается вместо подстановки. Если ни один вариант не
-- применим, подстановка вычищается - заменяется пустой строкой.
--
-- Пример: "в %регионе {stateProvince}|городе {city}|неизвестном
-- регионе%" при установленном stateProvince даёт "в регионе <значение>",
-- при пустом stateProvince и установленном city - "в городе <значение>",
-- при пустых обоих - "в неизвестном регионе".
--
-- Значения метаданных подставляются как есть, без обработки: "%%" в
-- значении остаётся "%%" (значения не сканируются повторно).
--
-- Вызывается в контексте асинхронной задачи (LrTasks): там обязаны
-- находиться вызовы getRawMetadata / getFormattedMetadata (см.
-- MetadataHelper.GetFormattedMetadata)
function PromptBuilder.Build(rawPrompt, photo)
    rawPrompt = rawPrompt or ""

    local result = {}
    local from = 1

    while true do
        local open = rawPrompt:find("%", from, true)

        if not open then
            table.insert(result, rawPrompt:sub(from))
            break
        end

        -- Текст до процентов: в нём не может быть "%", иначе find
        -- вернул бы именно её (пары "%%" обрабатываются веткой ниже)
        table.insert(result, rawPrompt:sub(from, open - 1))

        if rawPrompt:sub(open + 1, open + 1) == "%" then
            -- "%%" - литеральный процент, подстановку не открывает
            table.insert(result, "%")
            from = open + 2
        else
            local close = findClosingPercent(rawPrompt, open + 1)

            if not close then
                -- Незакрытая одиначная "%" остаётся литеральной
                table.insert(result, "%")
                from = open + 1
            else
                local content = rawPrompt:sub(open + 1, close - 1)

                -- "%%" внутри подстановки -> литеральный "%"
                content = content:gsub("%%%%", "%%")

                table.insert(result, buildSubstitution(content, photo))
                from = close + 1
            end
        end
    end

    return table.concat(result)
end

return PromptBuilder
