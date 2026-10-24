local LOC = LOC

local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrApplicationView = import 'LrApplicationView'
local LrTasks = import 'LrTasks'

local OpenAIWindow = require 'openai_window'
local PromptBuilder = require 'prompt_builder'
local PromptWindow = require 'prompt_window'
local Common = require 'common'

local SetupWindow = {}

local DEFAULT_FRAMING_PROMPT =
    'Locate the bird on photo, and provide its bounding frame. '
    .. 'Answer should contain only four numbers delimited by semicolon: '
    .. 'frame center X (in percents), frame center Y (in percents), '
    .. 'frame width (in percents), frame height (in percents), '
    .. 'without any markdown formatting, explanations, or code blocks.'

local DEFAULT_IDENTIFICATION_PROMPT =
    'Identify bird on photo taken in '
    .. '%region "{stateProvince}, {country}"|region "{stateProvince}"|country "{country}"|YOUR_DEFAULT_LOCATION% '
    .. '%on "{dateTimeOriginalISO8601}" (date and time specified in ISO 8601)%. '
    .. 'Provide response strictly in exactly two lines, with no formatting, markdown, '
    .. 'intro texts, explanations or punctuation. Use following format: '
    .. 'Line 1 - Official binomial scientific name of the species in Latin, '
    .. 'Line 2 - Accepted scientific common name of the species in %{Language} but formatted so that the noun comes first|Latin%.'

-- Отображает модальное окно настроек идентификации.
-- photo - выбранное фото: используется кнопками "Preview prompt"
--   (PromptBuilder подставляет метаданные фото в шаблон промпта) и для
--   формирования возвращаемых промптов. Фото гарантированно непустое:
--   выбор проверяется в identify_ai до открытия окна.
-- Все значения берутся из настроек плагина (LrPrefs) или задаются по умолчанию.
function SetupWindow.show(photo)
    local dialogResult = nil

    LrFunctionContext.callWithContext("setup_window", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        local prefs = LrPrefs.prefsForPlugin()

        -- Загрузка настроек окна из настроек плагина (один ключ, таблица
        -- через Common.serializeTable). Возвращает значения по умолчанию
        -- при первом открытии; из сохранённой таблицы берутся только
        -- известные поля с совпадающим типом. Состояние чекбокса промпта
        -- кадрирования (framingPromptEnabled) в настройки не сохраняется:
        -- оно вычисляется заново при каждом открытии окна (см. ниже)
        local function loadWindowState()
            local state = {
                compareAnswers = false,
                framingPrompt = DEFAULT_FRAMING_PROMPT,
                identificationPrompt = DEFAULT_IDENTIFICATION_PROMPT,
            }

            local stored = prefs["ai-setup-window"]
            local decoded = (type(stored) == "string")
                and Common.deserializeTable(stored) or nil
            if type(decoded) ~= "table" then
                return state
            end

            if type(decoded.compareAnswers) == "boolean" then
                state.compareAnswers = decoded.compareAnswers
            end

            if type(decoded.framingPrompt) == "string" and decoded.framingPrompt ~= "" then
                state.framingPrompt = decoded.framingPrompt
            end

            if type(decoded.identificationPrompt) == "string" and decoded.identificationPrompt ~= "" then
                state.identificationPrompt = decoded.identificationPrompt
            end

            return state
        end

        local windowState = loadWindowState()
        props.compareAnswers = windowState.compareAnswers
        props.framingPrompt = windowState.framingPrompt
        props.identificationPrompt = windowState.identificationPrompt

        -- Чекбокс промпта кадрирования по умолчанию включён только
        -- в модуле "Библиотека" (getCurrentModuleName возвращает имя
        -- активного модуля: "library", "develop" и др.)
        props.framingPromptEnabled =
            LrApplicationView.getCurrentModuleName() == "library"

        -- Локальные переменные для хранения настроек моделей текущей сессии
        local primaryModelSettings
        local consensusModelSettings

        -- Функция загрузки настроек из плагина или локальной переменной
        local function getOrLoadSettings(prefKey, localSettings)
            if localSettings then
                return localSettings
            end
            local savedStr = prefs[prefKey]
            if savedStr and savedStr ~= "" then
                local decoded = Common.deserializeTable(savedStr)
                if decoded then
                    return decoded
                end
            end
            return nil
        end

        -- Отображаем в полях названия моделей из сохранённых настроек
        -- плагина (поле model настроек каждой модели)
        local loadedPrimary = getOrLoadSettings("ai-primary-model", nil)
        props.primaryModel = (loadedPrimary and loadedPrimary.model) or ""

        local loadedConsensus = getOrLoadSettings("ai-consensus-model", nil)
        props.secondaryModel = (loadedConsensus and loadedConsensus.model) or ""

        -- Функция обработки нажатия кнопки "Setup".
        -- modelPropKey - имя свойства (props), в котором отображается название модели
        local function handleSetup(prefKey, getLocalSettings, setLocalSettings, modelPropKey)
            -- 1. Из настроек плагина взять строку по ключу
            local savedStr = prefs[prefKey]
            local modelData = nil

            -- 2. Полученная строка является Lua Table Literal
            if savedStr and savedStr ~= "" then
                modelData = Common.deserializeTable(savedStr)
            end

            -- Если в локальной переменной уже сохранены значения для текущей сессии, используем их
            local currentLocal = getLocalSettings()
            if currentLocal then
                modelData = currentLocal
            end

            modelData = modelData or {}

            -- 3. Открыть окно OpenAIWindow, передав значения
            -- 4. В OpenAIWindow отобразить полученные значения, а после редактирования вернуть новые значения в вызывающий код
            local result = OpenAIWindow.show(modelData)

            if result then
                local newSettings = {
                    baseUrl = result.baseUrl,
                    token = result.token,
                    model = result.model,
                    temperatureEnabled = result.temperatureEnabled,
                    temperature = result.temperature,
                    maxImageWidth = result.maxImageWidth,
                    maxImageHeight = result.maxImageHeight,
                }

                -- 5. Если OpenAIWindow закрылось как "Save and Use" - сохранить полученные значения в формате Lua Table Literal в настройки плагина
                if result.action == "save_and_use" then
                    prefs[prefKey] = Common.serializeTable(newSettings)
                end

                -- 6. Если OpenAIWindow закрылось как "Save and Use" или "Use once" - сохранить полученные значения в локальную переменную для дальнейшего использования
                if result.action == "save_and_use" or result.action == "use_once" then
                    setLocalSettings(newSettings)

                    -- Обновляем отображаемое название модели
                    if modelPropKey and result.model and result.model ~= "" then
                        props[modelPropKey] = result.model
                    end
                end
            end
        end

        -- Валидация: кнопка "Identify" активна только когда заполнены
        -- обязательные поля. secondaryModel обязателен лишь при включённом
        -- compareAnswers.
        local function trim(s)
            return (tostring(s or ""):match("^%s*(.-)%s*$"))
        end

        local function updateActionEnabled()
            local valid = trim(props.primaryModel) ~= ""
                and trim(props.identificationPrompt) ~= ""

            if valid and props.compareAnswers then
                valid = trim(props.secondaryModel) ~= ""
            end

            props.actionEnabled = valid
        end

        props:addObserver("primaryModel", updateActionEnabled)
        props:addObserver("identificationPrompt", updateActionEnabled)
        props:addObserver("secondaryModel", updateActionEnabled)
        props:addObserver("compareAnswers", updateActionEnabled)
        updateActionEnabled()

        -- Предпросмотр промпта (кнопки "Preview prompt"): PromptBuilder
        -- подставляет метаданные photo в шаблон поля, результат
        -- показывается в отдельном окне, поле промпта не меняется.
        -- photo:getFormattedMetadata требует контекста асинхронной
        -- задачи LrTasks, а обработчик кнопки выполняется вне задачи -
        -- поэтому сборка выполняется в startAsyncTask (по образцу
        -- openai_window); ошибка сборки показывается диалогом, так как
        -- необработанная ошибка обработчика кнопки не выводится
        local function showPromptPreview(rawPrompt)
            LrTasks.startAsyncTask(function()
                local ok, prompt = LrTasks.pcall(PromptBuilder.Build,
                    rawPrompt, photo)

                if not ok then
                    LrDialogs.message(LOC('$$$/AIWI/Setup/PromptErrorTitle=AIWI - Error'),
                        LOC('$$$/AIWI/Setup/PromptErrorText=Failed to build the prompt:^n')
                            .. tostring(prompt), "critical")
                    return
                end

                PromptWindow.show(prompt)
            end, "AIWI preview prompt")
        end

        -- Содержимое диалогового окна
        local contents = f:column {
            spacing = f:control_spacing(),
            bind_to_object = props,
            fill_horizontal = 1,
            width = 600,

            -- 1. Лейбл "Identification AI model:", поле "primaryModel" (read-only) и кнопка "Setup" справа
            f:row {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:static_text {
                    title = LOC('$$$/AIWI/Setup/ModelLabel=Identification AI model:'),
                    width = LrView.share("model_label_col"),
                },
                f:edit_field {
                    value = LrView.bind("primaryModel"),
                    fill_horizontal = 1,
                    enabled = false,
                },
                f:push_button {
                    title = LOC('$$$/AIWI/Setup/SetupButton=Setup'),
                    width = LrView.share("setup_btn_col"),
                    enabled = true,
                    action = function()
                        handleSetup(
                            "ai-primary-model",
                            function() return primaryModelSettings end,
                            function(val) primaryModelSettings = val end,
                            "primaryModel"
                        )
                    end,
                },
            },

            -- 2. Checkbox "Consensus AI model", поле "secondaryModel" (read-only) и кнопка "Setup" справа
            f:row {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:checkbox {
                    title = LOC('$$$/AIWI/Setup/ConsensusModel=Consensus AI model'),
                    value = LrView.bind("compareAnswers"),
                    width = LrView.share("model_label_col"),
                },
                f:edit_field {
                    value = LrView.bind("secondaryModel"),
                    fill_horizontal = 1,
                    enabled = false,
                },
                f:push_button {
                    title = LOC('$$$/AIWI/Setup/SetupButton=Setup'),
                    width = LrView.share("setup_btn_col"),
                    enabled = true,
                    action = function()
                        handleSetup(
                            "ai-consensus-model",
                            function() return consensusModelSettings end,
                            function(val) consensusModelSettings = val end,
                            "secondaryModel"
                        )
                    end,
                },
            },

            f:spacer { height = 5 },

            -- 3. Checkbox "Prompt for Subject framing:" и кнопка "Preview prompt"
            -- справа, под строкой - многострочное поле ввода промпта
            -- кадрирования. Выключение чекбокса не блокирует редактирование
            -- текста; значение поля сохраняется в настройках плагина,
            -- состояние чекбокса - нет (вычисляется по текущему модулю
            -- Lightroom при каждом открытии окна)
            f:column {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:row {
                    fill_horizontal = 1,
                    f:checkbox {
                        title = LOC('$$$/AIWI/Setup/FramingCheckbox=Prompt for Subject framing:'),
                        font = "<system/bold>",
                        value = LrView.bind("framingPromptEnabled"),
                    },
                    f:spacer {
                        fill_horizontal = 1,
                    },
                    f:push_button {
                        title = LOC('$$$/AIWI/Setup/PreviewButton=Preview prompt'),
                        width = LrView.share("setup_btn_col"),
                        action = function()
                            showPromptPreview(props.framingPrompt)
                        end,
                    },
                },
                f:edit_field {
                    value = LrView.bind("framingPrompt"),
                    height_in_lines = 8,
                    width_in_chars = 50,
                    fill_horizontal = 1,
                    wraps = true,
                    -- Enter вставляет перенос строки вместо нажатия
                    -- кнопки "Identify" по умолчанию
                    allow_newlines = true,
                },
            },

            f:spacer { height = 5 },

            -- 4. Многострочное поле ввода промпта идентификации
            -- с названием "Prompt for Subject identification:" и кнопкой
            -- "Preview prompt" справа
            f:column {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:row {
                    fill_horizontal = 1,
                    f:static_text {
                        title = LOC('$$$/AIWI/Setup/IdentificationLabel=Prompt for Subject identification:'),
                        font = "<system/bold>",
                    },
                    f:spacer {
                        fill_horizontal = 1,
                    },
                    f:push_button {
                        title = LOC('$$$/AIWI/Setup/PreviewButton=Preview prompt'),
                        width = LrView.share("setup_btn_col"),
                        action = function()
                            showPromptPreview(props.identificationPrompt)
                        end,
                    },
                },
                f:edit_field {
                    value = LrView.bind("identificationPrompt"),
                    height_in_lines = 8,
                    width_in_chars = 50,
                    fill_horizontal = 1,
                    wraps = true,
                    -- Enter вставляет перенос строки вместо нажатия
                    -- кнопки "Identify" по умолчанию
                    allow_newlines = true,
                },
            },

            f:spacer { height = 5 },
        }

        -- 5. Две кнопки в ряд: "Identify" и "Close"
        local result = LrDialogs.presentModalDialog({
            title = LOC('$$$/AIWI/Setup/Title=Photo Subject identification settings'),
            contents = contents,
            actionVerb = LOC('$$$/AIWI/Setup/IdentifyButton=Identify'),
            cancelVerb = LOC('$$$/AIWI/Setup/CloseButton=Close'),
            actionBinding = {
                enabled = {
                    bind_to_object = props,
                    key = "actionEnabled",
                },
            },
            resizable = "horizontally",
        })

        if result == "ok" then
            -- Сохраняем настройки окна одной таблицей в настройки
            -- плагина; промпты сохраняются ИСХОДНЫМИ шаблонами
            -- (без подстановок метаданных)
            local windowStateToSave = {
                compareAnswers = props.compareAnswers,
                framingPrompt = props.framingPrompt,
                identificationPrompt = props.identificationPrompt,
            }
            prefs["ai-setup-window"] = Common.serializeTable(windowStateToSave)

            -- Возвращаются СФОРМИРОВАННЫЕ промпты: PromptBuilder
            -- подставляет метаданные photo в шаблоны полей формы
            dialogResult = {
                action = "identify",
                primaryModel = props.primaryModel,
                compareAnswers = props.compareAnswers,
                secondaryModel = props.secondaryModel,
                identificationPrompt = PromptBuilder.Build(
                    props.identificationPrompt, photo),
                framingPromptEnabled = props.framingPromptEnabled,
                framingPrompt = PromptBuilder.Build(
                    props.framingPrompt, photo),
                primaryModelSettings = getOrLoadSettings("ai-primary-model", primaryModelSettings),
                consensusModelSettings = getOrLoadSettings("ai-consensus-model", consensusModelSettings),
            }
        else
            dialogResult = {
                action = "close",
                framingPromptEnabled = props.framingPromptEnabled,
            }
        end
    end)

    return dialogResult
end

return SetupWindow
