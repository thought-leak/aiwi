local LOC = LOC

local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'

local PhotoExport = {}

-- Качество JPEG при экспорте для анализа (%)
local EXPORT_JPEG_QUALITY = 60

-- Реестр временных файлов, созданных через exportIdentificationPhotoToTemp.
-- Очищается функцией cleanupTempFiles(), которая регистрируется в точке
-- входа плагина как cleanup-обработчик function context (см. identify_ai.lua)
local createdTempFiles = {}

-- Состояние экспорта, задаётся Initialize сразу после закрытия окна
-- настроек (см. identify_ai.lua)
local exportPhoto = nil           -- фото, которое будет экспортироваться
local useSettingsRollback = false -- true: настройки фото нужно восстановить
local savedRollbackSettings = nil -- сохранённые настройки (nil = нечего восстанавливать)
local developSettingsChanged = false -- true: кроп/AutoTone уже применены к фото

-- Настройки, которые меняет exportFramingPhotoToTemp (кроп и AutoTone).
-- Ключи взяты из документированного списка photo:getDevelopSettings():
-- при восстановлении применяются ТОЛЬКО они - значения неизменённых
-- ключей совпадают с текущими (безопасный no-op), а пропуск реально
-- изменённого ключа исключён для всех известных целей кропа и Auto
local ROLLBACK_SETTINGS_KEYS = {
    -- Кроп: ровно те 5 ключей, которые задаёт exportFramingPhotoToTemp
    "CropTop", "CropLeft", "CropBottom", "CropRight", "CropAngle",

    -- AutoTone: флаги авторежима (есть в getDevelopSettings)
    "AutoExposure", "AutoContrast", "AutoBrightness", "AutoShadows",

    -- AutoTone: тональные ползунки Basic, PV2012 и новее
    "Exposure2012", "Contrast2012", "Highlights2012",
    "Shadows2012", "Whites2012", "Blacks2012",

    -- AutoTone: тональные ползунки старого Process Version 2003
    "Exposure", "Contrast", "Brightness", "FillLight",
    "Blacks", "HighlightRecovery",
}

-- Инициализация состояния экспорта. Вызывается из identify_ai сразу после
-- закрытия окна настроек: сохраняет фото, которое будет экспортироваться,
-- и признак useSettingsRollback (= framingPromptEnabled из окна настроек).
-- При useSettingsRollback = true запоминаются настройки фото, которые
-- изменят кроп и AutoTone, - cleanupTempFiles восстановит их по завершении
-- работы. Виртуальные копии не создаются: SDK Lightroom не умеет удалять
-- фото, поэтому изменения применяются к оригиналу и откатываются.
-- Возвращает true; при отсутствии фото или невозможности сохранить
-- настройки - nil (критический диалог уже показан).
function PhotoExport.Initialize(photo, useSettingsRollbackFlag)
    exportPhoto = photo
    useSettingsRollback = useSettingsRollbackFlag == true
    savedRollbackSettings = nil
    developSettingsChanged = false

    if not photo then
        LrDialogs.message(
            LOC('$$$/AIWI/Export/ErrorTitle=AIWI - Error'),
            LOC('$$$/AIWI/Export/NoPhoto=No photo selected for identification.'),
            "critical"
        )
        return nil
    end

    if useSettingsRollback then
        local ok, settings = LrTasks.pcall(function()
            return photo:getDevelopSettings()
        end)

        if not ok or type(settings) ~= "table" then
            -- Без сохранённых настроек откат невозможен - прекращаем
            -- запуск, чтобы не оставить фото изменённым без восстановления
            useSettingsRollback = false
            LrDialogs.message(
                LOC('$$$/AIWI/Export/ErrorTitle=AIWI - Error'),
                LOC('$$$/AIWI/Export/SettingsSaveError=Failed to save photo settings for rollback: ^1',
                    tostring(settings)),
                "critical"
            )
            return nil
        end

        -- Откладываются только ключи ROLLBACK_SETTINGS_KEYS, реально
        -- присутствующие в настройках этого фото (отсутствующие ключи
        -- не восстанавливаются - они не менялись)
        local saved = {}
        for _, key in ipairs(ROLLBACK_SETTINGS_KEYS) do
            if settings[key] ~= nil then
                saved[key] = settings[key]
            end
        end
        savedRollbackSettings = saved
    end

    return true
end

-- Экспортирует фото во временный JPEG, ограничивая размер по maxImageWidth и
-- maxImageHeight из modelSettings (значений по умолчанию нет: размеры обязаны
-- быть заданы в настройках модели, без них экспорт идёт без ограничения), и
-- возвращает путь к временному файлу.
-- Возвращает nil и сообщение об ошибке при неудаче.
function PhotoExport.exportIdentificationPhotoToTemp(modelSettings)
    -- Фото хранится в состоянии модуля (задаётся в Initialize)
    local photo = exportPhoto
    if not photo then
        return nil, LOC('$$$/AIWI/Export/NotInitialized=Photo for export is not set: PhotoExport.Initialize was not called.')
    end

    local maxWidth = tonumber(modelSettings.maxImageWidth)
    local maxHeight = tonumber(modelSettings.maxImageHeight)

    local exportSettings = {
        -- Цель экспорта - временный каталог. Оба ключа обязательны:
        -- destinationType = "tempFolder" без указанного базового каталога
        -- destinationPathPrefix даёт ошибку экспорта; имя файла
        -- генерирует Lightroom
        ["LR_export_destinationType"] = "tempFolder",
        ["LR_export_destinationPathPrefix"] = LrPathUtils.getStandardFilePath("temp"),

        -- При совпадении имени с уже существующим файлом Lightroom
        -- генерирует уникальное имя (вариант "ask" в пакетной сессии
        -- недоступен)
        ["LR_collisionHandling"] = "rename",

        -- Формат и качество (LR_jpeg_quality задаётся шкалой 0..1,
        -- 1 - максимальное качество)
        ["LR_format"] = "JPEG",
        ["LR_jpeg_quality"] = EXPORT_JPEG_QUALITY / 100,
    }

    -- Ограничение размера включается только при указанных maxWidth и
    -- maxHeight: без LR_size_doConstrain = true (главный переключатель
    -- ресайза) размеры игнорируются, а doConstrain с незаданными
    -- maxWidth/maxHeight даёт битое изображение; resizeType = "wh" -
    -- вписывание в рамку maxWidth x maxHeight с сохранением пропорций
    if maxWidth and maxWidth > 0 and maxHeight and maxHeight > 0 then
        exportSettings["LR_size_doConstrain"] = true
        exportSettings["LR_size_resizeType"] = "wh"
        exportSettings["LR_size_doNotEnlarge"] = true
        exportSettings["LR_size_maxWidth"] = maxWidth
        exportSettings["LR_size_maxHeight"] = maxHeight
        exportSettings["LR_size_units"] = "pixels"
    end

    local exportSession = LrExportSession({
        photosToExport = { photo },
        exportSettings = exportSettings,
    })

    local exportedPath = nil
    local exportError = nil

    for _, rendition in exportSession:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if success then
            exportedPath = rendition.destinationPath or pathOrMessage
        else
            exportError = pathOrMessage
        end
    end

    if not exportedPath then
        return nil, exportError or LOC('$$$/AIWI/Export/NoExportResult=Photo export produced no result.')
    end

    if not LrFileUtils.exists(exportedPath) then
        return nil, LOC('$$$/AIWI/Export/FileNotFound=File not found after export: ^1', tostring(exportedPath))
    end

    -- Файл попадает в реестр: он будет удалён автоматически по
    -- завершении работы плагина (см. cleanupTempFiles)
    table.insert(createdTempFiles, exportedPath)

    return exportedPath, nil
end

-- Экспорт фото для анализа кадрирования: сначала с фотографии снимается
-- кадрирование, чтобы в экспорт попала вся фотография без обрезки, затем
-- применяются настройки, аналогичные кнопке "Auto" в панели Basic модуля
-- Develop, и выполняется экспорт через exportIdentificationPhotoToTemp.
-- Режим отображения Lightroom (активный модуль) не меняется.
-- Возвращает путь к временному файлу либо nil и сообщение об ошибке
-- (в т.ч. если не включён useSettingsRollback).
function PhotoExport.exportFramingPhotoToTemp(modelSettings)
    -- Фото хранится в состоянии модуля (задаётся в Initialize)
    local photo = exportPhoto
    if not photo then
        return nil, LOC('$$$/AIWI/Export/NotInitialized=Photo for export is not set: PhotoExport.Initialize was not called.')
    end

    -- Изменение настроек фото разрешено только при включённом откате:
    -- без useSettingsRollback кроп/AutoTone остались бы на фото навсегда
    if not useSettingsRollback then
        return nil, LOC('$$$/AIWI/Export/RollbackDisabled=useSettingsRollback (framingPromptEnabled) is not enabled: modifying photo settings is not allowed.')
    end

    -- Обёртка - LrTasks.pcall, а не стандартный Lua pcall: и гейт
    -- withWriteAccessDo, и SDK-вызовы внутри делают yield, а yield через
    -- границу обычного pcall (C-вызов или метаметод) запрещён -
    -- ошибка "Yielding is not allowed within a C or metamethod call"
    local developOk, developErr = LrTasks.pcall(function()
        -- applyDevelopSettings изменяет каталог и фактически требует
        -- гейта записи (в документации SDK это не указано - подтверждено
        -- ошибкой "must be called from within a withWriteAccessDo block")
        photo.catalog:withWriteAccessDo(
            LOC('$$$/AIWI/Export/PreparingProgress=AIWI: Preparing photo for export'),
            function()
                -- Выключаем кадрирование: прямоугольник кропа растягивается
                -- на весь кадр (нормированные координаты 0..1), угол кропа
                -- (выпрямление) обнуляется. AutoTone = true - авторежим
                -- тональности (аналог кнопки "Auto"); третий аргумент true
                -- разрешает auto-настройки синхронно, внутри вызова,
                -- чтобы экспорт сразу ниже уже увидел применённый Auto
                photo:applyDevelopSettings({
                    CropTop = 0,
                    CropLeft = 0,
                    CropBottom = 1,
                    CropRight = 1,
                    CropAngle = 0,
                    AutoTone = true,
                }, LOC('$$$/AIWI/Export/ResetCropTask=AIWI - Reset crop'), true)

                -- Страховочный вызов Auto Tone: применяет авторежим, даже если
                -- AutoTone в таблице настроек не поддержан данной версией Lightroom
                -- (метод документирован и не требует активного модуля Develop)
                -- LrDevelopController.setAutoTone()
            end
        )
    end)

    if not developOk then
        return nil, LOC('$$$/AIWI/Export/PrepareFailed=Failed to prepare photo for export: ^1', tostring(developErr))
    end

    -- Кроп и AutoTone применены - настройки нужно восстановить
    developSettingsChanged = true

    -- Экспорт (файл попадает в общий реестр временных файлов и будет
    -- удалён автоматически по завершении работы плагина)
    return PhotoExport.exportIdentificationPhotoToTemp(modelSettings)
end

-- Накладывает кроп на сохранённом в Initialize фото по координатам фрейма.
-- centerX, centerY - центр фрейма в процентах (от ширины и высоты фото,
--   начало координат - верхний левый угол);
-- frameWidth, frameHeight - ширина и высота фрейма в процентах от размера
--   фото; к каждой добавлен про запас 0.1 от их значения (10%), центр
--   фрейма остаётся на месте.
-- Прямоугольник кропа обрезается по краям фото; угол кропа обнуляется,
-- чтобы кроп лег ровно по указанным координатам. Требуется включённый
-- useSettingsRollback: применённый кроп восстановится в cleanupTempFiles.
-- Возвращает true либо nil и сообщение об ошибке (в т.ч. если не включён
-- useSettingsRollback).
function PhotoExport.ApplyFraming(centerX, centerY, frameWidth, frameHeight)
    -- Фото хранится в состоянии модуля (задаётся в Initialize)
    local photo = exportPhoto
    if not photo then
        return nil, LOC('$$$/AIWI/Export/NotInitialized=Photo for export is not set: PhotoExport.Initialize was not called.')
    end

    -- Изменение настроек фото разрешено только при включённом откате:
    -- без useSettingsRollback наложенный кроп остался бы на фото навсегда
    if not useSettingsRollback then
        return nil, LOC('$$$/AIWI/Export/RollbackDisabled=useSettingsRollback (framingPromptEnabled) is not enabled: modifying photo settings is not allowed.')
    end

    -- Проверка входных значений: четыре конечных числа
    for _, value in ipairs({ centerX, centerY, frameWidth, frameHeight }) do
        if type(value) ~= "number" or value ~= value
            or value == math.huge or value == -math.huge then
            return nil, LOC('$$$/AIWI/Export/InvalidFrameParams=Invalid frame parameters: four numbers expected.')
        end
    end

    if frameWidth <= 0 or frameHeight <= 0 then
        return nil, LOC('$$$/AIWI/Export/InvalidFrameSize=Invalid frame parameters: width and height must be greater than zero.')
    end

    -- Про запас: к ширине и высоте прибавляется 0.1 от их значения (10%),
    -- центр фрейма не смещается
    local cropWidth = frameWidth + frameWidth * 0.1
    local cropHeight = frameHeight + frameHeight * 0.1

    -- Прямоугольник кропа в нормированных координатах 0..1: от центра
    -- минус/плюс половина ширины и высоты; проценты делятся на 100
    local left = (centerX - cropWidth / 2) / 100
    local right = (centerX + cropWidth / 2) / 100
    local top = (centerY - cropHeight / 2) / 100
    local bottom = (centerY + cropHeight / 2) / 100

    -- Обрезка по краям фото
    left = math.max(0, math.min(1, left))
    right = math.max(0, math.min(1, right))
    top = math.max(0, math.min(1, top))
    bottom = math.max(0, math.min(1, bottom))

    if left >= right or top >= bottom then
        return nil, LOC('$$$/AIWI/Export/FrameOutside=The frame lies entirely outside the photo.')
    end

    -- Наложение кропа: изменение каталога, поэтому в гейте записи;
    -- обёртка LrTasks.pcall - withWriteAccessDo делает yield
    local applyOk, applyErr = LrTasks.pcall(function()
        photo.catalog:withWriteAccessDo(
            LOC('$$$/AIWI/Export/FramingProgress=AIWI: Applying framing'),
            function()
                photo:applyDevelopSettings({
                    CropTop = top,
                    CropLeft = left,
                    CropBottom = bottom,
                    CropRight = right,
                    CropAngle = 0,
                }, LOC('$$$/AIWI/Export/ApplyFramingTask=AIWI - Apply framing'))
            end
        )
    end)

    if not applyOk then
        return nil, LOC('$$$/AIWI/Export/ApplyFramingFailed=Failed to apply framing: ^1', tostring(applyErr))
    end

    -- Кроп применён - при включённом useSettingsRollback он восстановится
    -- в cleanupTempFiles
    developSettingsChanged = true

    return true
end

-- Завершающая очистка: удаляет все временные файлы экспорта, созданные
-- за время работы плагина, и восстанавливает настройки фото, если они
-- менялись (useSettingsRollback = true). Регистрируется через
-- context:addCleanupHandler в точке входа плагина, поэтому вызывается
-- автоматически после успешного завершения, ошибки или отмены.
-- Это ЕДИНСТВЕННОЕ место удаления временных файлов: никаких ранних
-- очисток в процессе работы нет. Повторное удаление файла безопасно:
-- уже удалённые пропускаются
function PhotoExport.cleanupTempFiles()
    -- 1. Временные файлы экспорта
    for i = #createdTempFiles, 1, -1 do
        local path = createdTempFiles[i]
        createdTempFiles[i] = nil
        if path and LrFileUtils.exists(path) then
            pcall(LrFileUtils.delete, path)
        end
    end

    -- 2. Восстановление настроек фото (кроп и AutoTone), если изменение
    -- выполнялось: в гейт подаются только сохранённые в Initialize ключи,
    -- значения применяются как есть, без повторного разрешения auto
    if useSettingsRollback and developSettingsChanged
        and exportPhoto and savedRollbackSettings
        and next(savedRollbackSettings) ~= nil then
        local photo = exportPhoto
        local settings = savedRollbackSettings

        local restoreOk, restoreErr = LrTasks.pcall(function()
            photo.catalog:withWriteAccessDo(
                LOC('$$$/AIWI/Export/RestoringProgress=AIWI: Restoring photo settings'),
                function()
                    photo:applyDevelopSettings(
                        settings, LOC('$$$/AIWI/Export/RestoreTask=AIWI - Restoring settings'))
                end
            )
        end)

        if not restoreOk then
            LrDialogs.message(
                LOC('$$$/AIWI/Export/ErrorTitle=AIWI - Error'),
                LOC('$$$/AIWI/Export/RestoreFailed=Failed to restore photo settings: ^1',
                    tostring(restoreErr)),
                "critical"
            )
        end
    end

    -- 3. Сброс состояния - следующий запуск инициализируется заново
    exportPhoto = nil
    useSettingsRollback = false
    savedRollbackSettings = nil
    developSettingsChanged = false
end

return PhotoExport
