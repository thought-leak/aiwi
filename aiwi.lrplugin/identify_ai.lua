local LOC = LOC

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'

local SetupWindow = require 'setup_window'
local ResultWindow = require 'result_window'
local OpenAIClient = require 'openai_client'
local PhotoExport = require 'photo_export'
local KeywordsHelper = require 'keywords_helper'
local MetadataHelper = require 'metadata_helper'

-- Очистка строки: убирает обрамляющие пробелы и символы "*"
local function cleanAnswerLine(line)
    if not line then return "" end
    -- Убираем пробелы, затем "*"; повторяем, т.к. удаление "*" может обнажить пробелы
    local cleaned = line
    for _ = 1, 2 do
        cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
        cleaned = cleaned:gsub("^%*+", ""):gsub("%*+$", "")
    end
    return cleaned
end

-- Разбивает ответ модели на строки по символам перевода строки
-- ('\n', '\r' и их комбинации), возвращает только ПЕРВЫЕ ДВЕ строки
-- (жёсткое ограничение): строки пустые НЕ удаляются, чтобы не
-- сбивалась нумерация, всё после второй строки отбрасывается.
-- Возвращает массив из одной-двух строк: при ответе в одну строку
-- второй элемент отсутствует
local function splitLinesLimited(text)
    local lines = {}
    if not text then return lines end

    -- Нормализуем переводы строк: '\r\n' и '\r' -> '\n'
    local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in normalized:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
        if #lines >= 2 then
            break
        end
    end

    return lines
end

-- Выполняет полный цикл: экспорт фото во временный JPEG и запрос к LLM.
-- modelSettings - настройки модели (baseUrl, token, model, temperature и т.д.)
-- prompt - текст запроса к модели
-- progress - (необязательно) LrProgressScope модального окна прогресса;
--   если передан, обновляются подпись и доля полосы прогресса
-- portionFrom, portionTo - (необязательно) границы доли полосы прогресса [0..1],
--   отведённой данному запросу (по умолчанию 0 и 1)
-- Возвращает три значения:
--   latinName (string)     - первая строка ответа (очищенная)
--   localizedName (string) - вторая строка ответа (очищенная);
--     пустая строка, если ответ состоит из одной строки
--   aiResponse (string)    - полный ответ модели без изменений
-- При любой ошибке или отмене возвращаются три пустые строки.
function GetAiConclusion(modelSettings, prompt, progress, portionFrom, portionTo)
    local EMPTY = ""

    portionFrom = portionFrom or 0
    portionTo = portionTo or 1

    -- Обновляет модальное окно прогресса (если оно передано)
    local function setProgress(caption, portion)
        if not progress then return end
        if caption then progress:setCaption(caption) end
        if portion then progress:setPortionComplete(portion) end
    end

    local modelName = tostring(modelSettings.model or "")

    -- 1. Экспорт фотографии во временный файл; само фото хранится
    -- в PhotoExport и задаётся в Initialize на шаге подготовки
    -- ветки identify (выбор фото проверяется в начале работы плагина)
    setProgress(LOC('$$$/AIWI/Identify/ExportingPhoto=Exporting photo (^1)...', modelName), portionFrom)

    local exportPath, exportErrMsg = PhotoExport.exportIdentificationPhotoToTemp(modelSettings)

    -- Экспорт - примерно треть работы одного запроса
    setProgress(nil, portionFrom + (portionTo - portionFrom) * 0.3)

    if not exportPath then
        LrDialogs.message(
            LOC('$$$/AIWI/Identify/ExportErrorTitle=AIWI - Export Error'),
            tostring(exportErrMsg),
            "critical"
        )
        return EMPTY, EMPTY, EMPTY
    end

    -- Пользователь отменил обработку - выходим без запроса к LLM.
    -- Временный файл удаляется только в конце работы плагина
    -- (cleanupTempFiles через addCleanupHandler)
    if progress and progress:isCanceled() then
        return EMPTY, EMPTY, EMPTY
    end

    -- 2. Запрос к LLM с временным файлом изображения
    setProgress(LOC('$$$/AIWI/Identify/RequestingModel=Requesting model (^1)...', modelName), nil)

    local conclusion, isSuccess = OpenAIClient.chat(modelSettings, prompt, exportPath)

    -- Временный файл экспорта здесь не удаляется: очистка выполняется
    -- только в конце работы плагина - cleanupTempFiles через
    -- addCleanupHandler (см. photo_export.lua)
    setProgress(nil, portionTo)

    if not isSuccess or not conclusion or conclusion == "" then
        -- Ошибка уже показана пользователю внутри OpenAIClient
        return EMPTY, EMPTY, EMPTY
    end

    -- 3. Разбираем ответ: первая строка - LatinName, вторая -
    -- LocalizedName, всё дальше отбрасывается (лимит splitLinesLimited).
    -- Ответ в одну строку - корректен: localizedName пустой.
    -- Полный ответ возвращаем без изменений.
    local lines = splitLinesLimited(conclusion)

    local latinName = cleanAnswerLine(lines[1])
    local localizedName = cleanAnswerLine(lines[2])

    return localizedName, latinName, conclusion
end

-- Объединение одноимённых значений, полученных от двух моделей.
-- Если значения равны - берётся любое из них.
-- Если одно значение является подстрокой другого - берётся то, которое содержит.
-- В остальных случаях возвращается пустая строка.
local function mergeNames(value1, value2)
    value1 = value1 or ""
    value2 = value2 or ""

    if value1 == value2 then
        return value1
    end

    -- Пустая строка является подстрокой любой строки,
    -- поэтому в этом случае вернётся непустое значение
    if value2:find(value1, 1, true) then
        return value2
    end

    if value1:find(value2, 1, true) then
        return value1
    end

    return ""
end

-- Создаёт динамическую (умную) коллекцию resultData.collectionNameText.
-- Бизнес-проверки (учёт collectionCreateEnabled, непустые name и
-- latinName) остаются здесь; условие отбора, родитель и вызов
-- createSmartCollection - в MetadataHelper.createDynamicCollection.
-- Вызывается внутри гейта записи каталога (требование createSmartCollection)
local function createDynamicCollection(resultData)
    if not resultData.collectionCreateEnabled then
        return false
    end

    local name = resultData.collectionNameText or ""
    if name == "" then
        return false
    end

    local latinName = resultData.latinName or ""
    if latinName == "" then
        return false
    end

    return MetadataHelper.createDynamicCollection(name, latinName,
        resultData.collectionInsideSetEnabled, resultData.collectionSetId)
end

-- Обрабатывает закрытие окна результатов с action == "save":
-- окно прогресса с общим количеством действий "выделенные фото + 1",
-- где последнее действие зарезервировано за созданием динамической
-- коллекции
local function handleSaveResult(resultData)
    -- ResultWindow не даёт сохранить пустой latinName; дошедший сюда
    -- пустой latinName означает нарушение этого контракта - сохранение
    -- отменяется с ошибкой
    if not resultData.latinName or resultData.latinName:match("^%s*$") then
        LrDialogs.message(
            LOC('$$$/AIWI/Identify/SaveErrorTitle=AIWI - Save Error'),
            LOC('$$$/AIWI/Identify/LatinNameMissing=Latin name is missing: the identification result is incomplete. Saving canceled.'),
            "critical"
        )
        return
    end

    local catalog = LrApplication.activeCatalog()
    local targetPhotos = catalog:getTargetPhotos()

    -- Общее число действий: по одному на фото плюс создание коллекции
    local totalSteps = #targetPhotos + 1
    local wasCanceled = false

    LrFunctionContext.callWithContext("identify_ai_save", function(context)
        local progress = LrDialogs.showModalProgressDialog({
            title = LOC('$$$/AIWI/Identify/SavingTitle=AIWI - Saving'),
            caption = LOC('$$$/AIWI/Identify/PreparingCaption=Preparing...'),
            width = 400,
            cannotCancel = false,
            functionContext = context,
        })

        local completedSteps = 0

        -- Отмечает завершённое действие: доля полосы = шаг / общее число
        local function completeStep()
            completedSteps = completedSteps + 1
            if progress then
                progress:setPortionComplete(completedSteps / totalSteps)
            end
        end

        -- Ключевые слова создаются отдельными гейтами до записи
        -- фотографий - по гейту на этап (корень, уровень 2, синонимы);
        -- весь код работы с keywords вынесен в keywords_helper.lua
        -- (localizedName - синоним уровня 2, привязывается только latinKeyword)
        local latinKeyword = KeywordsHelper.createHierarchy(
            catalog, resultData.latinName, resultData.localizedName, progress)

        -- Фотографии записываются одним гейтом доступа к каталогу
        local gateOk, gateErr = LrTasks.pcall(function()
            catalog:withWriteAccessDo(
                LOC('$$$/AIWI/Identify/SavingResults=AIWI: Saving identification results'),
                function()
                    for index, photo in ipairs(targetPhotos) do
                        if progress and progress:isCanceled() then
                            wasCanceled = true
                            break
                        end

                        if progress then
                            progress:setCaption(LOC(
                                '$$$/AIWI/Identify/SavingMetadata=Saving metadata (^1/^2)...',
                                index, #targetPhotos))
                        end

                        -- Все привязки ключевых слов AIWI снимаются один
                        -- раз до записи; привязывается заново только что
                        -- созданный keyword уровня 2 (latinName) - его
                        -- синоним localizedName едет вместе с ним
                        KeywordsHelper.removePluginKeywordLinks(photo)

                        if latinKeyword then
                            photo:addKeyword(latinKeyword)
                        end

                        -- Два набора настроек на каждую фотографию
                        -- (порядок: localizedName, latinName)
                        MetadataHelper.savePhotoMetadata(photo,
                            resultData.localizedName,
                            resultData.localizedSave)
                        MetadataHelper.savePhotoMetadata(photo,
                            resultData.latinName, resultData.latinSave)

                        completeStep()
                    end
                end)
        end)

        if not gateOk then
            LrDialogs.message(
                LOC('$$$/AIWI/Identify/SaveErrorTitle=AIWI - Save Error'),
                tostring(gateErr),
                "critical"
            )
        end

        if not wasCanceled then
            -- Последний шаг из totalSteps: создание динамической коллекции;
            -- выполняется только при включенном collectionCreateEnabled
            if resultData.collectionCreateEnabled then
                if progress then
                    progress:setCaption(LOC('$$$/AIWI/Identify/CreatingSmartCollection=Creating smart collection...'))
                end

                local collectionOk, collectionErr = LrTasks.pcall(function()
                    catalog:withWriteAccessDo(
                        LOC('$$$/AIWI/Identify/SmartCollectionTask=AIWI: Creating smart collection'),
                        function()
                            createDynamicCollection(resultData)
                        end)
                end)

                if not collectionOk then
                    LrDialogs.message(
                        LOC('$$$/AIWI/Identify/CollectionErrorTitle=AIWI - Collection Error'),
                        tostring(collectionErr),
                        "critical"
                    )
                end
            end

            -- Полоса прогресса заполняется полностью: фото + коллекция
            completeStep()
        end

        -- Закрываем окно прогресса (при отмене оно уже закрыто пользователем)
        if progress and not progress:isCanceled() then
            progress:done()
        end
    end)

    if wasCanceled then
        LrDialogs.showBezel(LOC('$$$/AIWI/Identify/SaveCanceledBezel=AIWI: save canceled'))
    end
end

-- Разбирает ответ модели кадрирования: четыре числа (возможно дробные),
-- разделённые точкой с запятой - центр X, центр Y и ширина, высота фрейма
-- (в процентах). В поле допустим конечный знак процента, десятичный
-- разделитель - точка или запятая.
-- Возвращает четыре числа либо nil, если ответ не разобран
local function parseFramingAnswer(answer)
    if type(answer) ~= "string" or answer == "" then
        return nil
    end

    -- Разбор одного поля: обрезка пробелов, отбрасывание конечного знака
    -- процента ("20%", "20 %"), запятая как десятичный разделитель
    -- ("45,5" -> "45,5" в виде "45.5")
    local function parseNumber(field)
        local cleaned = field:match("^%s*(.-)%s*$")
        cleaned = cleaned:match("^(.-)%s*%%$") or cleaned
        cleaned = cleaned:gsub(",", ".")
        return tonumber(cleaned)
    end

    -- Строгое разбиение по ";" с сохранением пустых полей, чтобы
    -- пропущенный разделитель не дал "четыре числа"
    local values = {}
    for field in (answer .. ";"):gmatch("(.-);") do
        local number = parseNumber(field)
        if not number then
            return nil
        end
        values[#values + 1] = number
    end

    if #values ~= 4 then
        return nil
    end

    return values[1], values[2], values[3], values[4]
end

-- Выполняет этап кадрирования (framing): экспорт фото целиком (кроп снят,
-- AutoTone применён - модель видит полный кадр), запрос к модели с промптом
-- кадрирования и наложение кропа по координатам из ответа. Запрос идёт
-- настройками основной модели. Все ошибки показываются диалогами;
-- временные файлы и изменённые настройки фото вернёт cleanupTempFiles
-- при завершении работы плагина.
-- progress - (необязательно) LrProgressScope модального окна прогресса;
--   обновляется подпись текущего действия этапа
-- Возвращает true либо nil - запуск плагина нужно прекратить
local function runFramingStep(setupResult, progress)
    local modelSettings = setupResult.primaryModelSettings

    -- 1. Экспорт фото во временный файл (фото уже задано в Initialize)
    if progress then
        progress:setCaption(LOC('$$$/AIWI/Identify/FramingExportingPhoto=Framing: exporting photo...'))
    end

    local exportPath, exportErrMsg =
        PhotoExport.exportFramingPhotoToTemp(modelSettings)
    if not exportPath then
        LrDialogs.message(
            LOC('$$$/AIWI/Identify/ExportErrorTitle=AIWI - Export Error'),
            tostring(exportErrMsg),
            "critical"
        )
        return nil
    end

    -- 2. Запрос к модели кадрирования настройками основной модели.
    -- При ошибке OpenAIClient.chat сам показывает диалог
    -- "LLM request error"
    if progress then
        progress:setCaption(LOC('$$$/AIWI/Identify/FramingRequestingModel=Framing: requesting model (^1)...',
            tostring(modelSettings.model or "")))
    end

    local answer, isSuccess = OpenAIClient.chat(modelSettings, setupResult.framingPrompt, exportPath)

    if not isSuccess or not answer or answer == "" then
        return nil
    end

    -- 3. Ответ - четыре числа через точку с запятой; иначе ошибка
    local frameX, frameY, frameWidth, frameHeight = parseFramingAnswer(answer)
    if not frameX then
        LrDialogs.message(
            LOC('$$$/AIWI/Identify/FramingErrorTitle=AIWI - Framing Error'),
            LOC('$$$/AIWI/Identify/FramingParseError=Failed to parse the framing model answer.^n'
                .. 'Four numbers separated by semicolons were expected^n'
                .. '(decimal values and a trailing percent sign are allowed).^n^n'
                .. 'Model answer:^n')
                .. answer,
            "critical"
        )
        return nil
    end

    -- 4. Наложение кропа по координатам фрейма (с запасом 10% внутри)
    if progress then
        progress:setCaption(LOC('$$$/AIWI/Identify/FramingApplying=Framing: applying framing...'))
    end

    local framingOk, framingErrMsg =
        PhotoExport.ApplyFraming(frameX, frameY, frameWidth, frameHeight)
    if not framingOk then
        LrDialogs.message(
            LOC('$$$/AIWI/Identify/FramingErrorTitle=AIWI - Framing Error'),
            tostring(framingErrMsg),
            "critical"
        )
        return nil
    end

    return true
end

-- Асинхронная задача с function context: cleanup-обработчики контекста
-- выполняются Lightroom после завершения работы - успешно, с ошибкой
-- или при отмене
LrFunctionContext.postAsyncTaskWithContext("identify_ai", function(context)
    -- Автоочистка временных файлов экспорта по завершении работы плагина
    context:addCleanupHandler(PhotoExport.cleanupTempFiles)

    -- 1. Получаем выбранное (открытое в UI) фото: оно нужно и для
    -- экспорта JPEG, и для окна настроек (предпросмотр промптов с
    -- метаданными фото). Без фото работу прекращаем
    local photo = LrApplication.activeCatalog():getTargetPhoto()

    if not photo then
        LrDialogs.message(
            LOC('$$$/AIWI/Identify/ErrorTitle=AIWI - Error'),
            LOC('$$$/AIWI/Identify/NoPhotoError=No photo selected for identification.'),
            "critical"
        )
        return
    end

    -- 2. Показываем сперва окно настроек идентификации
    local setupResult = SetupWindow.show(photo)

    -- 3. Если нажата кнопка "Identify", выполняем анализ и показываем окно результатов
    if setupResult and setupResult.action == "identify" then
        -- Переменные этапа обработки, заполняются внутри контекста прогресса
        local primaryLocalizedName, primaryLatinName, aiResponse = "", "", ""
        local consensusText = "(Consensus model disabled)"
        local consensusHasAnswer = false
        local consensusLocalizedName = ""
        local consensusLatinName = ""
        local wasCanceled = false
        local stepFailed = false

        -- 4. Весь этап анализа выполняется под модальным окном прогресса:
        -- окно появляется сразу при входе в ветку и закрывается при
        -- завершении function context - непосредственно перед показом
        -- окна результатов
        LrFunctionContext.callWithContext("identify_ai_progress", function(context)
            local progress = LrDialogs.showModalProgressDialog({
                title = LOC('$$$/AIWI/Identify/Title=AIWI - Identification'),
                caption = LOC('$$$/AIWI/Identify/PreparingCaption=Preparing...'),
                width = 400,
                cannotCancel = false,
                functionContext = context,
            })

            -- Шаги полосы: подготовка, опциональный этап кадрирования
            -- и запросы к моделям (основная плюс консенс при
            -- compareAnswers); каждый шаг - равная доля полосы
            local totalSteps = 2
                + (setupResult.framingPromptEnabled and 1 or 0)
                + (setupResult.compareAnswers and 1 or 0)
            local completedSteps = 0

            local function completeStep()
                completedSteps = completedSteps + 1
                if progress then
                    progress:setPortionComplete(completedSteps / totalSteps)
                end
            end

            -- 5. Инициализация PhotoExport: фото, которое будет
            -- экспортироваться, и признак useSettingsRollback (=
            -- framingPromptEnabled из окна настроек); при включенном
            -- признаке запоминаются настройки фото для восстановления
            -- в cleanupTempFiles. При отказе (нет фото либо не удалось
            -- сохранить настройки) критический диалог уже показан
            if progress then
                progress:setCaption(LOC('$$$/AIWI/Identify/PreparingPhoto=Preparing photo...'))
            end

            local initOk = PhotoExport.Initialize(
                photo,
                setupResult.framingPromptEnabled == true)

            if not initOk then
                stepFailed = true
                return
            end

            completeStep()

            -- 6. Этап кадрирования (framing): при включенном промпте
            -- кадрирования фото сперва кадрируется по координатам от
            -- модели - только затем начинается обычная идентификация.
            -- При отказе прекращаем работу: диалог уже показан, откат
            -- настроек и очистка файлов выполняются cleanupTempFiles
            if setupResult.framingPromptEnabled then
                if not runFramingStep(setupResult, progress) then
                    stepFailed = true
                    return
                end

                completeStep()

                -- Отмена во время кадрирования: запросы к моделям
                -- не выполняются
                if progress and progress:isCanceled() then
                    wasCanceled = true
                    return
                end
            end

            -- Доля полосы каждого запроса к модели: запросы идут
            -- последними шагами - при отключённом сравнении ответов
            -- основная модель получает остаток полосы целиком
            local stepShare = 1 / totalSteps

            -- 7. Запрос к основной модели
            local primaryFrom = completedSteps * stepShare

            primaryLocalizedName, primaryLatinName, aiResponse =
                GetAiConclusion(setupResult.primaryModelSettings, setupResult.identificationPrompt,
                    progress, primaryFrom, primaryFrom + stepShare)

            completeStep()

            if progress then
                wasCanceled = progress:isCanceled()
            end

            -- 8. Запрос к модели консенса - независимо от результата основной,
            -- только в зависимости от compareAnswers
            if not wasCanceled and setupResult.compareAnswers then
                local consensusFrom = completedSteps * stepShare

                consensusLocalizedName, consensusLatinName, consensusText =
                    GetAiConclusion(setupResult.consensusModelSettings, setupResult.identificationPrompt,
                        progress, consensusFrom, consensusFrom + stepShare)

                if consensusText == "" then
                    -- Ошибка уже показана в GetAiConclusion
                    consensusText = "(Consensus model returned no answer)"
                    consensusLocalizedName = ""
                    consensusLatinName = ""
                else
                    consensusHasAnswer = true
                end

                completeStep()
            end

            -- Закрываем окно прогресса (при отмене оно уже закрыто пользователем)
            if progress and not progress:isCanceled() then
                progress:done()
            end
        end)

        -- Ошибка шага (диалог уже показан) - прекращаем работу; откат
        -- настроек и очистка файлов выполняются cleanupTempFiles
        if stepFailed then
            return
        end

        -- Пользователь нажал "Cancel" в окне прогресса - анализ прерван,
        -- окно результатов не показывается
        if wasCanceled then
            LrDialogs.showBezel(LOC('$$$/AIWI/Identify/IdentificationCanceledBezel=AIWI: identification canceled'))
            return
        end

        -- 9. Объединение результатов. Если какая-то из моделей не ответила -
        -- берём значения той, что ответила; если обе - пустые строки
        local localizedName = primaryLocalizedName
        local latinName = primaryLatinName

        if consensusHasAnswer then
            if aiResponse ~= "" then
                localizedName = mergeNames(primaryLocalizedName, consensusLocalizedName)
                latinName = mergeNames(primaryLatinName, consensusLatinName)
            else
                -- Основная модель не ответила - используем значения модели консенса
                localizedName = consensusLocalizedName
                latinName = consensusLatinName
            end
        elseif aiResponse == "" then
            localizedName = ""
            latinName = ""
        end

        -- 8.1. Каталог задаёт локализованное название: если у keyword-а
        -- уровня 2 с именем latinName есть синоним (локализованное
        -- название, записанное плагином) - localizedName берётся оттуда
        -- (каноническое имя для латинского названия задаёт каталог);
        -- иначе остаётся значение, определённое на шаге 6
        if latinName ~= "" then
            local catalog = LrApplication.activeCatalog()
            local latinKeyword = KeywordsHelper.findLatinKeyword(catalog, latinName)
            local canonicalLocalizedName = latinKeyword
                and KeywordsHelper.getLocalizedName(latinKeyword)

            if canonicalLocalizedName then
                localizedName = canonicalLocalizedName
            end
        end

        -- 10. Окно результатов показывается в любом случае
        local resultData = ResultWindow.show({
            mainModelAnswer = aiResponse,
            consensusModelAnswer = consensusText,
            localizedName = localizedName,
            latinName = latinName,
            primaryLocalizedName = primaryLocalizedName,
            primaryLatinName = primaryLatinName,
            consensusLocalizedName = consensusLocalizedName,
            consensusLatinName = consensusLatinName,
            -- Флаг сравнения ответов моделей: влияет на статус и
            -- иконку в окне результатов
            compareAnswers = setupResult.compareAnswers,
        })

        if resultData and resultData.action == "save" then
            -- Сохранение метаданных по таблицам resultData.*Save
            -- (localizedSave, latinSave) и параметрам
            -- создания коллекции resultData.collection*
            handleSaveResult(resultData)
        end
    end
end)
