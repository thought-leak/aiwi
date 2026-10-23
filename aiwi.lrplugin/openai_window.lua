local LOC = LOC

local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrTasks = import 'LrTasks'

local OpenAIClient = require 'openai_client'

local OpenAIWindow = {}

-- Кеш списка моделей: последний успешный результат и значения
-- Base URL / Token, для которых он был получен
local cachedModels = nil
local cachedBaseUrl = nil
local cachedToken = nil

-- Возвращает список моделей { id, title } для текущих значений
-- полей редактирования baseUrl и token. Если оба значения совпадают
-- с сохранёнными в кеше и кеш есть - возвращается кеш без сетевого
-- запроса; иначе выполняется запрос списка и кеш обновляется.
-- Ошибка возвращается строкой (кеш при этом не меняется)
function OpenAIWindow.GetCachedModels(props)
    local baseUrl = props.baseUrl
    local token = props.token

    if cachedModels ~= nil
        and cachedBaseUrl == baseUrl
        and cachedToken == token then
        return cachedModels
    end

    local modelsOrError = OpenAIClient.GetModels(baseUrl, token)

    if type(modelsOrError) == "table" then
        cachedModels = modelsOrError
        cachedBaseUrl = baseUrl
        cachedToken = token
    end

    return modelsOrError
end

-- Отображает модальное окно настроек OpenAI
function OpenAIWindow.show(initialData)
    local dialogResult = nil

    LrFunctionContext.callWithContext("openai_window", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        initialData = initialData or {}
        if initialData.baseUrl ~= nil then
            props.baseUrl = initialData.baseUrl
        else
            props.baseUrl = "https://api.openai.com/v1"
        end

        props.token = initialData.token or ""

        props.model = initialData.model or ""

        if initialData.temperatureEnabled ~= nil then
            props.temperatureEnabled = initialData.temperatureEnabled
        else
            props.temperatureEnabled = true
        end

        props.temperature = initialData.temperature or 0.6
        props.maxImageWidth = initialData.maxImageWidth or 750
        props.maxImageHeight = initialData.maxImageHeight or 750

        -- Текст фильтра списка моделей: поле без лейбла в строке
        -- Model; используется только для фильтрации списка и из
        -- окна не возвращается
        props.filterText = ""

        -- Элементы выпадающего списка Model: обновляются при наборе
        -- текста фильтра (см. refreshModelItems ниже)
        props.modelItems = {}

        -- Валидация: пока одно из обязательных полей пустое, кнопки "Save and Use"
        -- и "Use once" деактивированы
        local REQUIRED_TEXT_FIELDS = { "baseUrl", "token", "model" }
        local REQUIRED_NUMBER_FIELDS = { "maxImageWidth", "maxImageHeight" }

        local function trim(s)
            return (tostring(s or ""):match("^%s*(.-)%s*$"))
        end

        local function updateActionEnabled()
            local valid = true

            for _, key in ipairs(REQUIRED_TEXT_FIELDS) do
                if trim(props[key]) == "" then
                    valid = false
                    break
                end
            end

            if valid then
                for _, key in ipairs(REQUIRED_NUMBER_FIELDS) do
                    local n = tonumber(props[key])
                    if n == nil or n <= 0 then
                        valid = false
                        break
                    end
                end
            end

            props.actionEnabled = valid
        end

        props.actionEnabled = false
        for _, key in ipairs(REQUIRED_TEXT_FIELDS) do
            props:addObserver(key, updateActionEnabled)
        end
        for _, key in ipairs(REQUIRED_NUMBER_FIELDS) do
            props:addObserver(key, updateActionEnabled)
        end
        updateActionEnabled()

        -- Значение информационного пункта "... and N more": строка,
        -- не могущая совпасть ни с одним реальным id модели
        local MORE_ITEM_VALUE = "\t__more_models__"

        -- Список элементов выпадающего списка Model. Подбор моделей
        -- двухступенчатый (поле фильтра без лейбла; его значение
        -- только управляет списком и из окна не возвращается,
        -- текстового поля модели нет):
        --   1) при вводе фильтра - точное (без учёта регистра)
        --      совпадение текста с id: такая модель становится
        --      первой строкой и текущим выбранным значением; если
        --      точного совпадения нет, первой строкой идёт текущий
        --      выбор (заголовок из кеша, при отсутствии в кеше - сам
        --      id), чтобы пользователь видел его в списке;
        --   2) текст разбивается по пробелам на слова, и
        --      добавляются модели, у которых каждое из слов -
        --      подстрока title (без учёта регистра); при пустом
        --      фильтре подходит любая модель. Добавление
        --      продолжается, пока вместе с первой строкой не
        --      наберётся 10 пунктов.
        -- Если подошедших моделей не все поместились в 10 строк, в
        -- конец списка добавляется информационный пункт
        -- "... and N more" (N - сколько подходящих не поместилось):
        -- сам он моделью не считается и в лимит 10 не входит.
        -- autoSelect - только при изменениях фильтра: иначе повторное
        -- применение точного совпадения по id отменило бы выбор,
        -- сделанный в popup. Кеш читается напрямую, без сетевого
        -- запроса (список обновляется при наборе фильтра и при
        -- выборе пункта)
        local function refreshModelItems(autoSelect)
            local query = trim(props.filterText):lower()
            local cacheMatches = cachedModels ~= nil
                and cachedBaseUrl == props.baseUrl
                and cachedToken == props.token
            local items = {}
            local totalMatches = 0
            local shownMatches = 0

            -- Слова фильтра: разбивка только по пробелам (пустые
            -- слова отбрасываются)
            local words = {}
            for word in query:gmatch("[^ ]+") do
                words[#words + 1] = word
            end

            -- 1-й этап: первая строка списка - точное совпадение
            -- по id (только при вводе фильтра)
            local firstId = nil
            local firstTitle = nil

            if autoSelect and cacheMatches and query ~= "" then
                for _, item in ipairs(cachedModels) do
                    local id = tostring(item.id or "")
                    if id:lower() == query then
                        firstId = id
                        firstTitle = id
                        if tostring(item.title or "") ~= "" then
                            firstTitle = tostring(item.title or "")
                        end

                        -- Точное совпадение по id становится текущим
                        -- выбранным значением; наблюдатель model при
                        -- этом пересоберёт список (без автовыбора) -
                        -- результат тот же
                        if props.model ~= firstId then
                            props.model = firstId
                        end
                        break
                    end
                end
            end

            -- Без точного совпадения первой строкой идёт текущий
            -- выбор: без него сохранённая модель могла бы не попасть
            -- в список и popup не отобразил бы её
            if firstId == nil then
                local selectedModel = trim(props.model)
                if selectedModel ~= "" then
                    firstId = selectedModel
                    firstTitle = selectedModel
                    if cacheMatches then
                        for _, cached in ipairs(cachedModels) do
                            if tostring(cached.id or "") == selectedModel
                                and cached.title ~= nil
                                and tostring(cached.title) ~= "" then
                                firstTitle = tostring(cached.title)
                                break
                            end
                        end
                    end
                end
            end

            if firstId ~= nil then
                items[#items + 1] = {
                    title = firstTitle,
                    value = firstId,
                }
            end

            -- 2-й этап: модели, у которых каждое из слов фильтра -
            -- подстрока title; добавляются, пока вместе с первой
            -- строкой не наберётся 10 пунктов
            if cacheMatches then
                for _, item in ipairs(cachedModels) do
                    local id = tostring(item.id or "")
                    local title = tostring(item.title or "")
                    local titleLower = title:lower()

                    local matches = true
                    for _, word in ipairs(words) do
                        if not titleLower:find(word, 1, true) then
                            matches = false
                            break
                        end
                    end

                    if matches then
                        totalMatches = totalMatches + 1
                        if id == firstId then
                            -- Модель первой строки уже показана
                            shownMatches = shownMatches + 1
                        elseif #items < 10 then
                            items[#items + 1] = {
                                title = title,
                                value = id,
                            }
                            shownMatches = shownMatches + 1
                        end
                    end
                end
            end

            -- Индикатор моделей, не поместившихся в список
            local hiddenCount = totalMatches - shownMatches
            if hiddenCount > 0 then
                items[#items + 1] = {
                    title = LOC('$$$/AIWI/OpenAI/AndMore=... and ^1 more', hiddenCount),
                    value = MORE_ITEM_VALUE,
                    -- SDK не описывает этот ключ (у пункта есть
                    -- только title и value); добавлен на случай
                    -- поддержки, фактическая невозможность выбора
                    -- обеспечивается откатом в обработчике model
                    disabled = true,
                }
            end

            props.modelItems = items
        end

        -- Загрузка списка моделей (кеш либо сетевой запрос).
        -- Сетевой запрос выполняется только в асинхронной задаче:
        -- LrHttp внутри обработчика кнопки модального окна зависает
        -- без ошибки (в прошлой версии это ломало кнопку Select)
        local function loadModelsAsync()
            LrTasks.startAsyncTask(function()
                local ok, result = LrTasks.pcall(function()
                    return OpenAIWindow.GetCachedModels(props)
                end)

                if not ok or type(result) ~= "table" then
                    -- Ошибка (исключение либо строка от GetModels)
                    -- показывается диалогом
                    LrDialogs.message(
                        LOC('$$$/AIWI/OpenAI/ModelsErrorTitle=Failed to get model list'),
                        tostring(result),
                        "critical")
                    return
                end

                refreshModelItems()
            end)
        end

        refreshModelItems()
        loadModelsAsync()

        -- Смена Base URL или Token меняет ключ кеша - список
        -- подгружается заново; текст фильтра меняет только элементы
        -- выпадающего списка (без сетевого запроса) и применяет
        -- автовыбор по точному совпадению с id. Выбор пункта
        -- popup меняет props.model - список пересобирается без
        -- автовыбора (иначе он отменил бы выбор из popup), чтобы
        -- закреплённая первая строка соответствовала выбору.
        -- SDK не умеет отключать пункты popup (items - только title
        -- и value), поэтому информационный пункт "... and N more"
        -- эмулируется: его выбор откатывается к предыдущему значению
        local previousModel = props.model
        props:addObserver("baseUrl", loadModelsAsync)
        props:addObserver("token", loadModelsAsync)
        props:addObserver("filterText", function()
            refreshModelItems(true)
        end)
        props:addObserver("model", function()
            if props.model == MORE_ITEM_VALUE then
                props.model = previousModel
                return
            end

            previousModel = props.model
            refreshModelItems()
        end)

        -- Содержимое диалогового окна
        local contents = f:column {
            spacing = f:control_spacing(),
            bind_to_object = props,
            fill_horizontal = 1,
            width = 500,

            -- 1. Однострочное поле ввода текста шириной во все окно с заголовком "Base URL:"
            f:column {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:static_text {
                    title = LOC('$$$/AIWI/OpenAI/BaseUrlLabel=Base URL:'),
                    font = "<system/bold>",
                },
                f:edit_field {
                    value = LrView.bind("baseUrl"),
                    fill_horizontal = 1,
                },
            },

            f:spacer { height = 5 },

            -- 2. Однострочное поле ввода текста шириной во все окно с заголовком "Token:"
            f:column {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:static_text {
                    title = LOC('$$$/AIWI/OpenAI/TokenLabel=Token:'),
                    font = "<system/bold>",
                },
                f:edit_field {
                    value = LrView.bind("token"),
                    fill_horizontal = 1,
                },
            },

            f:spacer { height = 5 },

            -- 3. Лейбл "Model:", слева - поле фильтра (без лейбла),
            -- справа - выпадающий список: вместе занимают всю
            -- ширину окна и одинаковой ширины (LrView.share задаёт
            -- одинаковые базовые ширины, fill_horizontal растягивает
            -- оба одинаково). Поле фильтра только управляет списком
            -- (до 10 моделей из кеша) и из окна не возвращается.
            -- Текстового поля выбранной модели нет: id сохраняется
            -- в props.model при выборе пункта списка (отображается
            -- как выбранный пункт popup) и возвращается из окна
            f:column {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:static_text {
                    title = LOC('$$$/AIWI/OpenAI/ModelLabel=Model:'),
                    font = "<system/bold>",
                },
                f:row {
                    spacing = f:label_spacing(),
                    fill_horizontal = 1,
                    f:edit_field {
                        value = LrView.bind("filterText"),
                        width = LrView.share("model_field_col"),
                        fill_horizontal = 1,
                        -- Элементы списка обновляются при наборе
                        immediate = true,
                    },
                    f:popup_menu {
                        items = LrView.bind("modelItems"),
                        value = LrView.bind("model"),
                        width = LrView.share("model_field_col"),
                        fill_horizontal = 1,
                    },
                },
            },

            f:spacer { height = 5 },

            -- 4. Checkbox "Temperature:" и справа от него однострочное поле ввода чисел от 0 до 2 с одной точкой после запятой шириной во все окно
            f:row {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:checkbox {
                    title = LOC('$$$/AIWI/OpenAI/TemperatureLabel=Temperature:'),
                    font = "<system/bold>",
                    value = LrView.bind("temperatureEnabled"),
                },
                f:edit_field {
                    value = LrView.bind("temperature"),
                    min = 0.0,
                    max = 2.0,
                    precision = 1,
                    increment = 0.1,
                    fill_horizontal = 1,
                    enabled = LrView.bind("temperatureEnabled"),
                },
            },

            f:spacer { height = 5 },

            -- 5. Заголовок "Maximum image size:" после которого поле ввода целых чисел на 7 знаков далее знак "x" и еще одно поле ввода целых чисел на 7 знаков
            f:row {
                spacing = f:label_spacing(),
                f:static_text {
                    title = LOC('$$$/AIWI/OpenAI/MaxImageSizeLabel=Maximum image size:'),
                    font = "<system/bold>",
                },
                f:edit_field {
                    value = LrView.bind("maxImageWidth"),
                    width_in_digits = 7,
                    min = 1,
                    max = 9999999,
                    precision = 0,
                },
                f:static_text {
                    title = "x",
                },
                f:edit_field {
                    value = LrView.bind("maxImageHeight"),
                    width_in_digits = 7,
                    min = 1,
                    max = 9999999,
                    precision = 0,
                },
            },
        }

        -- 5. В последнем ряду три кнопки: "Save and Use" (по умолчанию), "Use once", "Cancel"
        local result = LrDialogs.presentModalDialog({
            title = LOC('$$$/AIWI/OpenAI/Title=OpenAI Settings'),
            contents = contents,
            actionVerb = LOC('$$$/AIWI/OpenAI/SaveAndUseButton=Save and Use'),
            otherVerb = LOC('$$$/AIWI/OpenAI/UseOnceButton=Use once'),
            cancelVerb = LOC('$$$/AIWI/OpenAI/CancelButton=Cancel'),
            actionBinding = {
                enabled = {
                    bind_to_object = props,
                    key = "actionEnabled",
                },
            },
            otherBinding = {
                enabled = {
                    bind_to_object = props,
                    key = "actionEnabled",
                },
            },
            resizable = "horizontally",
        })

        if result == "ok" then
            -- Кнопка "Save and Use"
            dialogResult = {
                action = "save_and_use",
                baseUrl = props.baseUrl,
                token = props.token,
                model = props.model,
                temperatureEnabled = props.temperatureEnabled,
                temperature = props.temperature,
                maxImageWidth = props.maxImageWidth,
                maxImageHeight = props.maxImageHeight,
            }
        elseif result == "other" then
            -- Кнопка "Use once"
            dialogResult = {
                action = "use_once",
                baseUrl = props.baseUrl,
                token = props.token,
                model = props.model,
                temperatureEnabled = props.temperatureEnabled,
                temperature = props.temperature,
                maxImageWidth = props.maxImageWidth,
                maxImageHeight = props.maxImageHeight,
            }
        else
            dialogResult = {
                action = "cancel",
            }
        end
    end)

    return dialogResult
end

return OpenAIWindow
