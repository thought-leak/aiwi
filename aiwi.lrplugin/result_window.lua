local LOC = LOC

local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

local Common = require 'common'
local AnswerWindow = require 'answer_window'

local ResultWindow = {}

-- Прочерк, отображаемый на кнопке, если значение пустое
local DASH = "—"

-- Пути к иконкам статуса идентификации (файлы в папке плагина)
local ICON_GREEN = LrPathUtils.child(_PLUGIN.path, "green_26.png")
local ICON_YELLOW = LrPathUtils.child(_PLUGIN.path, "yellow_26.png")
local ICON_RED = LrPathUtils.child(_PLUGIN.path, "red_26.png")

-- Служебные значения списка TargetField (секция "Save to"): строка,
-- не совпадающая ни с одним тегом метаданных (ведущий символ табуляции
-- исключает совпадение). "<don't save to field>" - ничего не сохранять,
-- "<specified field>" - сохранять в произвольное поле (его имя задаётся
-- в поле CustomFieldName и в этом режиме доступно для редактирования)
local SAVE_TARGET_DONT = "\t__dont_save_to_field__"
local SAVE_TARGET_SPECIFIED = "\t__specified_field__"

-- Пункты выпадающего списка TargetField: первым - служебный пункт
-- "<don't save to field>", далее - целевые поля метаданных (value -
-- соответствующий тег Lightroom, ключи getRawMetadata/setRawMetadata;
-- altTextAccessibility и extDescrAccessibility - с SDK 13.2),
-- последним - "<specified field>". Общий список для обеих секций
-- "Save to" (латинной и локализованной); пункт выбран всегда. Режим
-- обычного поля задаётся выбором его тега
local SAVE_TARGET_ITEMS = {
    { title = LOC("$$$/AIWI/Result/TargetDontSave=<don't save to field>"), value = SAVE_TARGET_DONT },
    { title = LOC('$$$/AIWI/Result/TargetFieldTitle=Title'),                 value = "title" },
    { title = LOC('$$$/AIWI/Result/TargetFieldCaption=Caption'),               value = "caption" },
    { title = LOC('$$$/AIWI/Result/TargetAltText=Alt Text'),              value = "altTextAccessibility" },
    { title = LOC('$$$/AIWI/Result/TargetExtDescr=Extended Description'),  value = "extDescrAccessibility" },
    { title = LOC("$$$/AIWI/Result/TargetSpecified=<specified field>"),     value = SAVE_TARGET_SPECIFIED },
}

-- Отображает модальное окно с результатами идентификации
function ResultWindow.show(initialData)
    local dialogResult = nil

    LrFunctionContext.callWithContext("result_window", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        initialData = initialData or {}
        props.mainModelAnswer = initialData.mainModelAnswer or ""
        props.consensusModelAnswer = initialData.consensusModelAnswer or ""
        props.localizedName = initialData.localizedName or ""
        props.latinName = initialData.latinName or ""

        -- Флаг сравнения ответов моделей (секция консенса окна
        -- настроек): участвует в определении статуса и иконки
        props.compareAnswers = initialData.compareAnswers or false

        -- Настройки плагина
        local prefs = LrPrefs.prefsForPlugin()

        -- Загрузка параметров одной секции "Save to".
        -- Все параметры хранятся в настройках одним ключом (prefKey)
        -- в виде таблицы, сериализованной через Common.serializeTable.
        -- defaultSettings - таблица значений по умолчанию для конкретной
        -- секции; перечисляются только отличия от базовых дефолтов
        -- (все чекбоксы выключены, target-поле и имя произвольного поля
        -- пустые).
        -- Возвращает таблицу с параметрами: из сохранённой берутся только
        -- известные поля с типом, совпадающим с типом значения по умолчанию.
        local function loadSaveSettings(prefKey, defaultSettings)
            local defaults = {
                targetFieldEnabled = false,
                targetField = "",
                customFieldEnabled = false,
                customFieldName = "",
            }

            -- Отличия дефолтов для конкретной секции
            for key, value in pairs(defaultSettings or {}) do
                defaults[key] = value
            end

            local stored = prefs[prefKey]
            local decoded = (type(stored) == "string") and Common.deserializeTable(stored) or nil
            if type(decoded) ~= "table" then
                return defaults
            end

            local settings = {}
            for key, defaultValue in pairs(defaults) do
                local value = decoded[key]
                settings[key] = (type(value) == type(defaultValue)) and value or defaultValue
            end
            return settings
        end

        -- Загрузка состояния блока "Collection" из настроек плагина
        -- (один ключ, таблица через Common.serializeTable). Возвращает
        -- значения по умолчанию при первом открытии; из сохранённой
        -- таблицы берутся только известные поля с корректным значением:
        -- индекс - в диапазоне своего списка, чекбоксы - boolean,
        -- collectionSetId - "" либо number (существование collection set
        -- проверяется позже, по построенному списку)
        local function loadWindowState()
            local state = {
                collectionCreateEnabled = false,
                collectionNameIndex = 1,
                collectionInsideSetEnabled = false,
                collectionSetId = "",
            }

            local stored = prefs["ai-result-window"]
            local decoded = (type(stored) == "string")
                and Common.deserializeTable(stored) or nil
            if type(decoded) ~= "table" then
                return state
            end

            local nameIndex = decoded.collectionNameIndex
            if type(nameIndex) == "number"
                and nameIndex >= 1 and nameIndex <= 4 then
                state.collectionNameIndex = nameIndex
            end

            if type(decoded.collectionCreateEnabled) == "boolean" then
                state.collectionCreateEnabled = decoded.collectionCreateEnabled
            end

            if type(decoded.collectionInsideSetEnabled) == "boolean" then
                state.collectionInsideSetEnabled = decoded.collectionInsideSetEnabled
            end

            local collectionSetId = decoded.collectionSetId
            if collectionSetId == "" or type(collectionSetId) == "number" then
                state.collectionSetId = collectionSetId
            end

            return state
        end

        -- Дефолты секций: у названий сразу включено целевое поле
        -- (localized -> caption, latin -> altTextAccessibility).
        -- Привязка ключевых слов секций названий включена всегда,
        -- без флажков: latinName - уровень 2 иерархии AIWI
        -- (localizedName - его синоним)
        local localizedSaveSettings = loadSaveSettings("ai-localized-save", {
            targetFieldEnabled = true,
            targetField = "caption",
        })
        local latinSaveSettings = loadSaveSettings("ai-latin-save", {
            targetFieldEnabled = true,
            targetField = "altTextAccessibility",
        })

        -- Состояние блока "Collection" восстанавливается из настроек
        -- (значения по умолчанию - при первом открытии):
        -- collectionNameIndex - вариант имени коллекции
        -- (1 - localizedName, 2 - latinName, 3 - "localizedName /
        -- latinName", 4 - "latinName / localizedName"), хранится как
        -- индекс, чтобы выбор оставался устойчивым при пересчёте подписей
        -- элементов списка; collectionSetId - идентификатор выбранного
        -- collection set ("" - не выбран). Тексты опций списка и общий
        -- ключ пересчитываются в updateOptionTexts при открытии окна
        local windowState = loadWindowState()

        props.collectionCreateEnabled = windowState.collectionCreateEnabled
        props.collectionNameIndex = windowState.collectionNameIndex
        props.collectionInsideSetEnabled = windowState.collectionInsideSetEnabled
        props.collectionSetId = windowState.collectionSetId

        -- Параметры отображаются в свойствах окна: привязки в LR SDK
        -- работают только с плоскими именами свойств. Режим секции
        -- "Save to" задаётся выбранным пунктом списка TargetField;
        -- нормализация загруженных значений приводит его к одному
        -- из трёх вариантов
        local function saveToPopupValue(settings)
            local field = settings.targetField
            if settings.targetFieldEnabled and field ~= ""
                and field ~= SAVE_TARGET_DONT
                and field ~= SAVE_TARGET_SPECIFIED then
                return field
            end
            if settings.customFieldEnabled then
                return SAVE_TARGET_SPECIFIED
            end
            return SAVE_TARGET_DONT
        end

        props.localizedTargetField = saveToPopupValue(localizedSaveSettings)
        props.localizedCustomFieldName = localizedSaveSettings.customFieldName

        -- Keyword латинского названия привязывается всегда (без флажка)
        props.latinTargetField = saveToPopupValue(latinSaveSettings)
        props.latinCustomFieldName = latinSaveSettings.customFieldName

        -- Флаги секции "Save to" вычисляются из выбранного пункта:
        -- обычное поле - сохранение в него (произвольное поле
        -- недоступно), "<specified field>" - в произвольное поле
        -- (его имя доступно для редактирования), "<don't save to
        -- field>" - ничего не сохранять. Флаги хранятся в настройках
        -- и возвращаются из окна (identify_ai использует их при
        -- записи в метаданные)
        local function updateSaveToState(prefix)
            local value = props[prefix .. "TargetField"]
            props[prefix .. "TargetFieldEnabled"] =
                value ~= SAVE_TARGET_DONT and value ~= SAVE_TARGET_SPECIFIED
            props[prefix .. "CustomFieldEnabled"] =
                value == SAVE_TARGET_SPECIFIED
        end

        props:addObserver("localizedTargetField", function()
            updateSaveToState("localized")
        end)
        props:addObserver("latinTargetField", function()
            updateSaveToState("latin")
        end)
        updateSaveToState("localized")
        updateSaveToState("latin")

        local function trim(s)
            return (tostring(s or ""):match("^%s*(.-)%s*$"))
        end

        -- Настройка пары кнопок выбора значения для одного из полей:
        -- captionProp/enableProp/valueProp - имена свойств кнопки,
        -- primaryValue/consensusValue - значения от основной модели
        -- и модели консенса. Пустое значение даёт прочерк
        -- и недоступную для нажатия кнопку.
        local function setupNameButtons(captionProp, enableProp, valueProp, primaryValue, consensusValue)
            local primary = trim(primaryValue)
            local consensus = trim(consensusValue)

            props[captionProp .. "Primary"] = primary ~= "" and primary or DASH
            props[enableProp .. "Primary"] = primary ~= ""
            props[valueProp .. "Primary"] = primary

            props[captionProp .. "Consensus"] = consensus ~= "" and consensus or DASH
            props[enableProp .. "Consensus"] = consensus ~= ""
            props[valueProp .. "Consensus"] = consensus
        end

        setupNameButtons(
            "localizedBtnCaption", "localizedBtnEnabled", "localizedBtnValue",
            initialData.primaryLocalizedName, initialData.consensusLocalizedName
        )
        setupNameButtons(
            "latinBtnCaption", "latinBtnEnabled", "latinBtnValue",
            initialData.primaryLatinName, initialData.consensusLatinName
        )

        -- Секция "Save to" для одного из полей названий (prefix -
        -- "localized" или "latin"). Привязка ключевых слов секции -
        -- всегда, без флажков: latinName - уровень 2 иерархии AIWI,
        -- localizedName - его синоним. Одна строка: надпись "Save to",
        -- список TargetField (задаёт режим секции) и имя
        -- произвольного поля; оба поля одной ширины (общий
        -- share-объект LrView.share + fill_horizontal) и вместе с
        -- надписью занимают всю ширину окна. Имя произвольного поля
        -- редактируется только в режиме "<specified field>"
        -- (enabled привязан к флагу customFieldEnabled)
        local function saveToRow(prefix)
            return f:row {
                spacing = f:label_spacing(),
                fill_horizontal = 1,

                f:static_text {
                    title = LOC('$$$/AIWI/Result/SaveTo=Save to'),
                },
                f:popup_menu {
                    width = LrView.share("save_to_field"),
                    value = LrView.bind(prefix .. "TargetField"),
                    items = SAVE_TARGET_ITEMS,
                    fill_horizontal = 1,
                },
                f:edit_field {
                    width = LrView.share("save_to_field"),
                    value = LrView.bind(prefix .. "CustomFieldName"),
                    enabled = LrView.bind(prefix .. "CustomFieldEnabled"),
                    fill_horizontal = 1,
                },
            }
        end

        -- Валидация: кнопка "Save" активна только когда заполнено
        -- обязательное поле "Latin name", а при включенном
        -- "Inside collection set" - ещё и выбран collection set
        -- (collectionSetId не пуст); "Localized name" может быть пустым
        local function updateActionEnabled()
            local latinFilled = trim(props.latinName) ~= ""

            local collectionSetFilled = not props.collectionInsideSetEnabled
                or props.collectionSetId ~= ""

            props.actionEnabled = latinFilled and collectionSetFilled
        end

        props:addObserver("latinName", updateActionEnabled)
        props:addObserver("collectionInsideSetEnabled", updateActionEnabled)
        props:addObserver("collectionSetId", updateActionEnabled)
        updateActionEnabled()

        -- Текст лейбла статуса идентификации и путь к его иконке.
        -- Вычисляется один раз при открытии окна исключительно по
        -- входным значениям (последующие изменения полей формы на
        -- статус и иконку не влияют). Формула:
        -- 1. "Identified with consensus" (зелёная иконка) - непустой
        --    latinName при включённом compareAnswers;
        -- 2. "Identified" (зелёная иконка) - непустой latinName без
        --    compareAnswers;
        -- 3. "No consensus reached" (жёлтая иконка) - пустой latinName
        --    при включённом compareAnswers и одном из ответов моделей
        --    (primaryLatinName/consensusLatinName);
        -- 4. "Identification failed" (красная иконка) - во всех
        --    прочих случаях (latinName пуст)
        local function computeIdentificationStatus()
            local latinFilled = trim(props.latinName) ~= ""
            local anyModelAnswer = trim(props.latinBtnValuePrimary) ~= ""
                or trim(props.latinBtnValueConsensus) ~= ""

            if latinFilled and props.compareAnswers then
                props.identificationStatus = LOC('$$$/AIWI/Result/StatusIdentifiedConsensus=Identified with consensus')
                props.identificationIcon = ICON_GREEN
            elseif latinFilled then
                props.identificationStatus = LOC('$$$/AIWI/Result/StatusIdentified=Identified')
                props.identificationIcon = ICON_GREEN
            elseif props.compareAnswers and anyModelAnswer then
                props.identificationStatus = LOC('$$$/AIWI/Result/StatusNoConsensus=No consensus reached')
                props.identificationIcon = ICON_YELLOW
            else
                props.identificationStatus = LOC('$$$/AIWI/Result/StatusFailed=Identification failed')
                props.identificationIcon = ICON_RED
            end
        end

        -- Однократный расчёт по входным значениям - без наблюдателей
        computeIdentificationStatus()

        -- Текст комбинации названий для вариантов имени коллекции.
        -- Пустое значение не участвует в комбинации (не остаётся
        -- висячего разделителя)
        local function combineNames(first, second)
            local parts = {}
            if trim(first) ~= "" then parts[#parts + 1] = first end
            if trim(second) ~= "" then parts[#parts + 1] = second end
            return table.concat(parts, " / ")
        end

        -- Пересчёт текста выбранного варианта имени коллекции и общего
        -- ключа привязки items для списка "Collection": подписи элементов
        -- обновляются при правке названий и при смене выбранной опции
        local function updateOptionTexts()
            -- Текст выбранного варианта имени коллекции - возвращается
            -- из формы
            if props.collectionNameIndex == 2 then
                props.collectionNameText = props.latinName
            elseif props.collectionNameIndex == 3 then
                props.collectionNameText =
                    combineNames(props.localizedName, props.latinName)
            elseif props.collectionNameIndex == 4 then
                props.collectionNameText =
                    combineNames(props.latinName, props.localizedName)
            else
                props.collectionNameText = props.localizedName
            end

            -- Общий ключ привязки items: меняется при любом изменении
            -- одного из названий или выбранной опции. Устанавливается
            -- последним - transform пересчитает подписи уже по
            -- обновлённым значениям
            props.optionsSignature = props.localizedName .. "\n"
                .. props.latinName .. "\n" .. props.collectionNameIndex
        end

        props:addObserver("localizedName", updateOptionTexts)
        props:addObserver("latinName", updateOptionTexts)
        props:addObserver("collectionNameIndex", updateOptionTexts)
        updateOptionTexts()

        -- Перечень существующих collection set для выпадающего списка:
        -- заголовок - имя с отступом уровней вложенности (корень - без
        -- отступа, каждый следующий уровень - на 4 пробела больше),
        -- значение - идентификатор. Список собирается
        -- один раз при открытии окна: модальный диалог блокирует
        -- изменение каталога. Идентификатор доступен только внутри
        -- гейта записи каталога (LrCollectionSet.localIdentifier);
        -- при отказе гейта список остаётся пустым
        local catalog = LrApplication.activeCatalog()
        local collectionSetItems = {}
        local gateOk = LrTasks.pcall(function()
            catalog:withWriteAccessDo(
                LOC('$$$/AIWI/Result/ReadCollectionSets=AIWI: Reading collection sets'),
                function()
                    local function appendCollectionSets(sets, depth)
                        for _, collectionSet in ipairs(sets or {}) do
                            collectionSetItems[#collectionSetItems + 1] = {
                                -- Отступ на каждый уровень вложенности
                                -- перед названием (у корня - без отступа)
                                title = string.rep("    ", depth)
                                    .. collectionSet:getName(),
                                value = collectionSet.localIdentifier,
                            }
                            appendCollectionSets(
                                collectionSet:getChildCollectionSets(),
                                depth + 1)
                        end
                    end

                    appendCollectionSets(catalog:getChildCollectionSets(), 0)
                end)
        end)
        if not gateOk then
            collectionSetItems = {}
        end

        -- Восстановленный из настроек идентификатор collection set
        -- принимается, только если set есть в текущем списке (он мог
        -- быть удалён); сброс значения вызывает наблюдатель и пересчёт
        -- доступности кнопки "Save". При отказе гейта список пуст
        -- и проверка не выполняется - сохранённое значение остаётся
        -- как есть
        if gateOk and props.collectionSetId ~= "" then
            local setIdFound = false
            for _, item in ipairs(collectionSetItems) do
                if item.value == props.collectionSetId then
                    setIdFound = true
                    break
                end
            end
            if not setIdFound then
                props.collectionSetId = ""
            end
        end

        -- Содержимое диалогового окна
        local contents = f:column {
            spacing = f:control_spacing(),
            bind_to_object = props,
            fill_horizontal = 1,
            -- Ширина - под верхнюю строку (лейбл статуса и две кнопки
            -- ответов моделей)
            width = 550,

            -- 1. Иконка и лейбл статуса идентификации и две кнопки
            -- просмотра ответов моделей, прижатые к правому краю окна
            f:row {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                -- Иконка статуса: путь вычисляется свойством
                -- identificationIcon по входным данным при открытии
                -- окна (см. computeIdentificationStatus)
                f:picture {
                    value = LrView.bind("identificationIcon"),
                },
                f:static_text {
                    title = LrView.bind("identificationStatus"),
                    font = "<system/bold>",
                },
                f:spacer {
                    fill_horizontal = 1,
                },
                -- Ответ основной модели открывается в окне AnswerWindow
                f:push_button {
                    title = LOC('$$$/AIWI/Result/PrimaryAnswerButton=Primary AI answer'),
                    action = function()
                        AnswerWindow.show(LOC('$$$/AIWI/Result/PrimaryAnswerTitle=Main model answer'), props.mainModelAnswer)
                    end,
                },
                -- Ответ модели консенса открывается в окне AnswerWindow
                f:push_button {
                    title = LOC('$$$/AIWI/Result/ConsensusAnswerButton=Consensus AI answer'),
                    action = function()
                        AnswerWindow.show(LOC('$$$/AIWI/Result/ConsensusAnswerTitle=Consensus model answer'), props.consensusModelAnswer)
                    end,
                },
            },

            f:spacer { height = 5 },

            -- 2. Строка с заголовком "Latin name:" и двумя кнопками справа,
            -- под строкой - поле ввода значения и секция "Save to"
            f:column {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:row {
                    fill_horizontal = 1,
                    spacing = f:label_spacing(),
                    f:static_text {
                        title = LOC('$$$/AIWI/Result/LatinNameLabel=Latin name:'),
                        font = "<system/bold>",
                    },
                    f:spacer {
                        fill_horizontal = 1,
                    },
                    -- Значение от основной модели (primaryModelSettings)
                    f:push_button {
                        title = LrView.bind("latinBtnCaptionPrimary"),
                        enabled = LrView.bind("latinBtnEnabledPrimary"),
                        action = function()
                            props.latinName = props.latinBtnValuePrimary
                        end,
                    },
                    -- Значение от модели консенса (consensusModelSettings)
                    f:push_button {
                        title = LrView.bind("latinBtnCaptionConsensus"),
                        enabled = LrView.bind("latinBtnEnabledConsensus"),
                        action = function()
                            props.latinName = props.latinBtnValueConsensus
                        end,
                    },
                },
                f:edit_field {
                    value = LrView.bind("latinName"),
                    fill_horizontal = 1,
                },
                -- Секция "Save to" - куда сохранять латинское название
                saveToRow("latin"),
            },

            f:spacer { height = 5 },

            -- 3. Строка с заголовком "Localized name:" и двумя кнопками справа,
            -- под строкой - поле ввода значения и секция "Save to"
            f:column {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:row {
                    fill_horizontal = 1,
                    spacing = f:label_spacing(),
                    f:static_text {
                        title = LOC('$$$/AIWI/Result/LocalizedNameLabel=Localized name:'),
                        font = "<system/bold>",
                    },
                    f:spacer {
                        fill_horizontal = 1,
                    },
                    -- Значение от основной модели (primaryModelSettings)
                    f:push_button {
                        title = LrView.bind("localizedBtnCaptionPrimary"),
                        enabled = LrView.bind("localizedBtnEnabledPrimary"),
                        action = function()
                            props.localizedName = props.localizedBtnValuePrimary
                        end,
                    },
                    -- Значение от модели консенса (consensusModelSettings)
                    f:push_button {
                        title = LrView.bind("localizedBtnCaptionConsensus"),
                        enabled = LrView.bind("localizedBtnEnabledConsensus"),
                        action = function()
                            props.localizedName = props.localizedBtnValueConsensus
                        end,
                    },
                },
                f:edit_field {
                    value = LrView.bind("localizedName"),
                    fill_horizontal = 1,
                },
                -- Секция "Save to" - куда сохранять локализованное название
                saveToRow("localized"),
            },

            f:spacer { height = 5 },

            -- 4. Блок "Collection": лейбл, строка с чекбоксом создания
            -- и списком вариантов имени, строка с чекбоксом и списком
            -- collection set (оба списка выровнены по правому краю)
            f:column {
                spacing = f:label_spacing(),
                fill_horizontal = 1,
                f:static_text {
                    title = LOC('$$$/AIWI/Result/CollectionLabel=Collection:'),
                    font = "<system/bold>",
                },
                -- Строка 1: чекбокс слева и список вариантов имени
                -- во всю оставшуюся ширину
                f:row {
                    spacing = f:label_spacing(),
                    fill_horizontal = 1,
                    f:checkbox {
                        title = LOC('$$$/AIWI/Result/CreateCollection=Create if not exists'),
                        value = LrView.bind("collectionCreateEnabled"),
                    },
                    f:popup_menu {
                        -- Подписи - текущие значения свойств и обновляются
                        -- общим ключом optionsSignature: transform
                        -- пересчитывает подписи при правке названий и
                        -- смене выбранной опции
                        items = LrView.bind {
                            key = "optionsSignature",
                            transform = function(value, fromModel)
                                if not fromModel then
                                    -- Односторонняя привязка: items
                                    -- обновляются только из модели
                                    return LrBinding.kUnsupportedDirection
                                end
                                return {
                                    {
                                        title = props.localizedName,
                                        value = 1,
                                    },
                                    {
                                        title = props.latinName,
                                        value = 2,
                                    },
                                    {
                                        title = combineNames(props.localizedName,
                                            props.latinName),
                                        value = 3,
                                    },
                                    {
                                        title = combineNames(props.latinName,
                                            props.localizedName),
                                        value = 4,
                                    },
                                }
                            end,
                        },
                        -- В props хранится индекс варианта (1 - localized,
                        -- 2 - latin, 3 - "localizedName / latinName",
                        -- 4 - "latinName / localizedName"), текст
                        -- возвращается из формы в props.collectionNameText
                        value = LrView.bind("collectionNameIndex"),
                        fill_horizontal = 1,
                    },
                },
                -- Строка 2: чекбокс и список существующих collection set,
                -- прижатые к правому краю
                f:row {
                    spacing = f:label_spacing(),
                    fill_horizontal = 1,
                    f:spacer {
                        fill_horizontal = 1,
                    },
                    f:checkbox {
                        title = LOC('$$$/AIWI/Result/InsideCollectionSet=Inside collection set'),
                        value = LrView.bind("collectionInsideSetEnabled"),
                    },
                    f:popup_menu {
                        -- Заголовки - имена collection set с отступами
                        -- уровней вложенности, значения -
                        -- их идентификаторы; список статичен, пока
                        -- открыто модальное окно
                        items = collectionSetItems,
                        -- В props хранится идентификатор выбранного
                        -- collection set ("" - ничего не выбрано)
                        value = LrView.bind("collectionSetId"),
                    },
                },
            },

            f:spacer { height = 5 },
        }

        -- 5. Две кнопки: "Save" и "Cancel"
        local result = LrDialogs.presentModalDialog({
            title = LOC('$$$/AIWI/Result/Title=Identification Results'),
            contents = contents,
            actionVerb = LOC('$$$/AIWI/Result/SaveButton=Save'),
            cancelVerb = LOC('$$$/AIWI/Result/CancelButton=Cancel'),
            actionBinding = {
                enabled = {
                    bind_to_object = props,
                    key = "actionEnabled",
                },
            },
            resizable = true,
        })

        if result == "ok" then
            -- Параметры секции "Save to" - по одной таблице на секцию
            -- (привязка ключевых слов секций названий - всегда, без
            -- отдельного параметра). Тег целевого поля хранится только
            -- при выбранном обычном поле - для служебных пунктов
            -- списка - пустая строка; режим при следующем открытии
            -- восстанавливается по флагам (см. saveToPopupValue)
            local function buildSaveSettings(prefix)
                local enabled = props[prefix .. "TargetFieldEnabled"]
                return {
                    targetFieldEnabled = enabled,
                    targetField = enabled and props[prefix .. "TargetField"] or "",
                    customFieldEnabled = props[prefix .. "CustomFieldEnabled"],
                    customFieldName = props[prefix .. "CustomFieldName"],
                }
            end

            local localizedSave = buildSaveSettings("localized")
            local latinSave = buildSaveSettings("latin")

            -- Две таблицы сохраняем в настройки плагина (2 ключа)
            prefs["ai-localized-save"] = Common.serializeTable(localizedSave)
            prefs["ai-latin-save"] = Common.serializeTable(latinSave)

            -- Состояние блока "Collection" сохраняем
            -- как значения по умолчанию при следующем открытии окна
            local windowStateToSave = {
                collectionCreateEnabled = props.collectionCreateEnabled,
                collectionNameIndex = props.collectionNameIndex,
                collectionInsideSetEnabled = props.collectionInsideSetEnabled,
                collectionSetId = props.collectionSetId,
            }
            prefs["ai-result-window"] = Common.serializeTable(windowStateToSave)

            dialogResult = {
                action = "save",
                localizedName = props.localizedName,
                latinName = props.latinName,
                -- Блок Collection: чекбоксы, текст выбранного варианта
                -- имени коллекции и идентификатор collection set
                collectionCreateEnabled = props.collectionCreateEnabled,
                collectionNameText = props.collectionNameText,
                collectionInsideSetEnabled = props.collectionInsideSetEnabled,
                collectionSetId = props.collectionSetId,
                -- Параметры секции "Save to" для каждой из секций
                localizedSave = localizedSave,
                latinSave = latinSave,
            }
        else
            dialogResult = {
                action = "cancel",
            }
        end
    end)

    return dialogResult
end

return ResultWindow
