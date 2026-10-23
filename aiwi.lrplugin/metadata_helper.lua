local LrApplication = import 'LrApplication'

-- LOC - глобальная функция локализации Lightroom: import
-- 'LrLocalization' возвращает таблицу без поля LOC
local LOC = LOC

local MetadataHelper = {}

-- Сохраняет строку value в метаданные photo в зависимости от параметров
-- секции "Save to" (localizedSave / latinSave):
--   targetFieldEnabled - значение уходит в поле targetField
--     (тег метаданных Lightroom);
--   customFieldEnabled - значение уходит в поле с именем customFieldName.
-- Ключевые слова пишутся отдельно в keywords_helper: привязка идёт
-- готовыми объектами из гейта создания, а не здесь.
-- Вызывается дважды для каждой фотографии (localized, latin) внутри
-- гейта записи каталога (setRawMetadata требует гейта)
function MetadataHelper.savePhotoMetadata(photo, value, saveSettings)
    if not saveSettings then
        return
    end

    value = value or ""

    if saveSettings.targetFieldEnabled and saveSettings.targetField ~= "" then
        photo:setRawMetadata(saveSettings.targetField, value)
    end

    if saveSettings.customFieldEnabled and saveSettings.customFieldName ~= "" then
        photo:setRawMetadata(saveSettings.customFieldName, value)
    end
end

-- Создаёт умную коллекцию name с условием отбора - keyword второго
-- уровня иерархии плагина (latinName под AIWI, привязывается к фото
-- всегда): criteria "keywords" - поле из документированного списка
-- criteria у LrCatalog:findPhotos, оператор "==" - точное совпадение
-- имени keyword (условия по targetField / customField не создаются).
-- Родитель - коллекция с идентификатором collectionSetId, если включен
-- insideSet и ID не пуст, иначе - корневой уровень каталога.
-- canReturnPrior = true: существующая коллекция с таким именем
-- возвращается без создания дубликата.
-- Бизнес-проверки (учёт collectionCreateEnabled, непустые name и
-- latinName) - на стороне вызывающего кода (identify_ai).
-- Вызывается внутри гейта записи каталога (требование createSmartCollection).
-- Возвращает true, если коллекция создана или переиспользована
function MetadataHelper.createDynamicCollection(name, latinName, insideSet,
        collectionSetId)
    local condition = {
        criteria = "keywords",
        operation = "==",
        value = latinName,
    }

    -- Родитель: коллекция с указанным ID либо корень каталога
    local catalog = LrApplication.activeCatalog()
    local parent = nil
    if insideSet and (collectionSetId or "") ~= "" then
        parent = catalog:getCollectionByLocalIdentifier(collectionSetId)
    end

    local collection = catalog:createSmartCollection(
        name, condition, parent, true)
    return collection ~= nil
end

-- Ключи getRawMetadata, значения которых SDK возвращает строками
-- (полный список ключей с типами - в документации SDK,
-- LrPhoto.getRawMetadata)
local RAW_STRING_KEYS = {
    altTextAccessibility = true,
    colorNameForLabel = true,
    copyrightState = true,
    dateTimeDigitizedISO8601 = true,
    dateTimeISO8601 = true,
    dateTimeOriginalISO8601 = true,
    extDescrAccessibility = true,
    fileFormat = true,
    path = true,
    uuid = true,
}

-- Ключи getRawMetadata, значения которых SDK возвращает числами.
-- Даты-штампы (dateTimeOriginal, dateTimeDigitized, dateTime,
-- lastEditTime) сюда не включены: это внутреннее число секунд, чья
-- конверсия в строку бесполезна; для таких ключей (как и для прочих
-- нестрочных/нечисловых - таблицы, массивы, флажки) используется
-- getFormattedMetadata, а машиночитаемая дата есть в RAW_STRING_KEYS
-- в виде *ISO8601-ключей
local RAW_NUMBER_KEYS = {
    aperture = true,
    aspectRatio = true,
    bitDepth = true,
    countStackInFolderMembers = true,
    countVirtualCopies = true,
    durationInSeconds = true,
    editCount = true,
    exposureBias = true,
    fileSize = true,
    focalLength = true,
    focalLength35mm = true,
    gpsAltitude = true,
    gpsImgDirection = true,
    height = true,
    isoSpeedRating = true,
    pickStatus = true,
    rating = true,
    shutterSpeed = true,
    stackPositionInFolder = true,
    trimmedDurationInSeconds = true,
    width = true,
}

-- Возвращает значение метаданных photo по ключу key для подстановки
-- в промпт (вызывается из prompt_builder):
--   "Language" - язык интерфейса Lightroom (от фото не зависит):
--     LOC("$$$/AIWI/Language=English") - значение из словаря
--     локализации плагина (TranslatedStrings_*.txt: "Russian",
--     "Chinese Simplified"), при отсутствии перевода - "English";
--   ключ из RAW_STRING_KEYS - сырое строковое значение getRawMetadata;
--   ключ из RAW_NUMBER_KEYS - сырое число getRawMetadata,
--     конвертированное в строку;
--   прочие ключи - дисплейное значение getFormattedMetadata.
-- Сопоставление со списками - точное, чувствительное к регистру.
-- Возвращает nil, если значения нет.
-- Вызывается в контексте асинхронной задачи (LrTasks): там обязаны
-- находиться вызовы getRawMetadata / getFormattedMetadata
function MetadataHelper.GetFormattedMetadata(photo, key)
    -- Язык интерфейса: значение словаря локализации плагина по
    -- ключу "$$$/AIWI/Language"; без перевода - "English" (дефолт
    -- ZString, заданный в коде)
    if key == "Language" then
        return LOC("$$$/AIWI/Language=English")
    end

    if RAW_STRING_KEYS[key] then
        return photo:getRawMetadata(key)
    end

    if RAW_NUMBER_KEYS[key] then
        local value = photo:getRawMetadata(key)
        return value and tostring(value) or nil
    end

    return photo:getFormattedMetadata(key)
end

return MetadataHelper
