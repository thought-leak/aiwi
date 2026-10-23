local LOC = LOC

local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'

local KeywordsHelper = {}

-- Корень иерархии ключевых слов плагина (уровень 1). Структура:
-- AIWI / <latinName> (уровень 2); localizedName хранится СИНОНИМОМ
-- уровня 2. К фото привязывается только уровень 2 - синоним едет
-- вместе с ним. Все синонимы ключевых слов иерархии принадлежат
-- плагину. Каждый уровень может уже существовать - тогда
-- используется существующее keyword с таким же родителем
local KEYWORD_ROOT = "AIWI"

-- Находит keyword уровня 2 иерархии плагина: имя latinName прямо под
-- корнем KEYWORD_ROOT. Возвращает LrKeyword или nil, если не найден.
-- Вызывается в контексте асинхронной задачи (LrTasks)
function KeywordsHelper.findLatinKeyword(catalog, latinName)
    if (latinName or "") == "" then
        return nil
    end

    for _, keyword in ipairs(catalog:getKeywords()) do
        if keyword:getName() == KEYWORD_ROOT then
            for _, child in ipairs(keyword:getChildren()) do
                if child:getName() == latinName then
                    return child
                end
            end
        end
    end

    return nil
end

-- Возвращает локализованное название - синоним латинского keyword-а
-- (строка) или nil, если синонимов нет.
--
-- Все синонимы иерархии AIWI принадлежат плагину: плагин пишет ровно
-- один синоним (localizedName), поэтому каноническое имя для
-- латинского названия задаёт каталог напрямую. Nil - канонического
-- имени нет (например, слот очищен при сохранении с пустым именем) -
-- остаётся значение, определённое ИИ.
-- Вызывается в контексте асинхронной задачи (LrTasks)
function KeywordsHelper.getLocalizedName(latinKeyword)
    local synonyms = latinKeyword:getSynonyms() or {}
    return synonyms[1]
end

-- Удаляет с фото привязки всех ключевых слов, входящих в иерархию
-- AIWI, независимо от уровня и дальнейших дочерних значений. Удаляются
-- только привязки к фото: сами ключевые слова остаются в каталоге
function KeywordsHelper.removePluginKeywordLinks(photo)
    local function belongsToPlugin(keyword)
        -- Топовый предок ключевого слова - корень плагина
        local top = keyword
        while top:getParent() do
            top = top:getParent()
        end

        return top:getName() == KEYWORD_ROOT
    end

    for _, keyword in ipairs(photo:getRawMetadata("keywords") or {}) do
        if belongsToPlugin(keyword) then
            photo:removeKeyword(keyword)
        end
    end
end

-- Создаёт иерархию ключевых слов ДО записи фотографий, отдельным
-- гейтом на каждый этап: корень, уровень 2, синонимы. По документации
-- createKeyword новый keyword "is not available for access until
-- that function returns" - объект keyword из свежего createKeyword
-- непригоден внутри того же гейта, поэтому каждый этап работает
-- с результатом предыдущего только после выхода из его гейта.
-- Иерархия: AIWI / <latinName>; слот синонима уровня 2 принадлежит
-- плагину целиком: непустое localizedName записывается единственным
-- синонимом (прежний список заменяется), пустое (валидный случай)
-- очищает слот - синонимов не остаётся. Узлы переиспользуют уже
-- существующее keyword с таким же родителем (returnExisting = true).
-- catalog - активный каталог, latinName/localizedName - названия
-- результата, progress - (необязательно) LrProgressScope для подписи.
-- Возвращает latinKeyword; при ошибке любого этапа - критический
-- диалог и nil (запись остальных метаданных продолжается без keyword).
-- Вызывается в контексте асинхронной задачи (LrTasks)
function KeywordsHelper.createHierarchy(catalog, latinName, localizedName, progress)
    if progress then
        progress:setCaption(LOC('$$$/AIWI/Keywords/Progress=Creating keywords...'))
    end

    local latinKeyword = nil
    local rootKeyword

    local keywordOk, keywordErr = LrTasks.pcall(function()
        -- Этап 1: общий корень иерархии. synonyms - только пустая таблица:
        -- nil Lightroom отвергает внутри SDK ошибкой "bad argument #2 to 'format'"
        catalog:withWriteAccessDo(
            LOC('$$$/AIWI/Keywords/RootTask=AIWI: Creating root keyword'),
            function()
                rootKeyword = catalog:createKeyword(
                    KEYWORD_ROOT, {}, true, nil, true)
            end)

        -- Этап 2: latinName - уровень 2, привязывается к фото
        if rootKeyword then
            catalog:withWriteAccessDo(
                LOC('$$$/AIWI/Keywords/Level2Task=AIWI: Creating level-2 keyword'),
                function()
                    latinKeyword = catalog:createKeyword(
                        latinName, {}, true, rootKeyword, true)
                end)
        end

        -- Этап 3: слот синонимов принадлежит плагину целиком: список
        -- заменяется одним значением localizedName; пустое имя (валидный
        -- случай) очищает слот - синонимов не остаётся
        if latinKeyword then
            local synonyms = {}
            if localizedName and not localizedName:match("^%s*$") then
                synonyms = { localizedName }
            end

            catalog:withWriteAccessDo(
                LOC('$$$/AIWI/Keywords/SynonymsTask=AIWI: Creating keyword synonyms'),
                function()
                    latinKeyword:setAttributes({ synonyms = synonyms })
                end)
        end
    end)

    if not keywordOk then
        -- Запись остальных метаданных продолжается без keyword
        LrDialogs.message(
            LOC('$$$/AIWI/Keywords/ErrorTitle=AIWI - Keyword Error'),
            tostring(keywordErr),
            "critical"
        )
        return nil
    end

    return latinKeyword
end

return KeywordsHelper
