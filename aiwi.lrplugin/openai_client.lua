local LOC = LOC

local LrHttp = import 'LrHttp'
local LrDialogs = import 'LrDialogs'

local OpenAIClient = {}

local Json = require 'json'

-- --------------------------------------------------------------------------
-- Base64 кодирование бинарных данных
-- --------------------------------------------------------------------------
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64table = {}
for i = 1, 64 do
    b64table[i - 1] = b64chars:sub(i, i)
end

local function base64Encode(data)
    local len = #data
    local t = {}
    local math_floor = math.floor
    local string_byte = string.byte

    for i = 1, len, 3 do
        local b1 = string_byte(data, i)
        local b2 = string_byte(data, i + 1) or 0
        local b3 = string_byte(data, i + 2) or 0

        local c1 = math_floor(b1 / 4)
        local c2 = (b1 % 4) * 16 + math_floor(b2 / 16)
        local c3 = (b2 % 16) * 4 + math_floor(b3 / 64)
        local c4 = b3 % 64

        table.insert(t, b64table[c1])
        table.insert(t, b64table[c2])
        if i + 1 <= len then
            table.insert(t, b64table[c3])
        else
            table.insert(t, '=')
        end
        if i + 2 <= len then
            table.insert(t, b64table[c4])
        else
            table.insert(t, '=')
        end
    end
    return table.concat(t)
end

-- --------------------------------------------------------------------------
-- Определение MIME-типа по расширению файла
-- --------------------------------------------------------------------------
local function getMimeType(filePath)
    local ext = filePath:match("%.([^%.]+)$")
    if ext then
        ext = ext:lower()
        if ext == "jpg" or ext == "jpeg" then
            return "image/jpeg"
        elseif ext == "png" then
            return "image/png"
        elseif ext == "webp" then
            return "image/webp"
        elseif ext == "gif" then
            return "image/gif"
        end
    end
    return "image/jpeg"
end

-- --------------------------------------------------------------------------
-- Чтение бинарного файла с диска
-- --------------------------------------------------------------------------
local function readFileBinary(filePath)
    local file, err = io.open(filePath, "rb")
    if not file then
        return nil, LOC('$$$/AIWI/Client/OpenImageFailed=Failed to open image file: ^1', tostring(err))
    end
    local content = file:read("*a")
    file:close()
    if not content or #content == 0 then
        return nil, LOC('$$$/AIWI/Client/EmptyImage=Image file is empty: ^1', tostring(filePath))
    end
    return content
end

-- --------------------------------------------------------------------------
-- Отображение ошибки пользователю
-- --------------------------------------------------------------------------
local function reportError(errMsg)
    LrDialogs.message(LOC('$$$/AIWI/Client/RequestErrorTitle=LLM request error'), tostring(errMsg), "critical")
end

-- --------------------------------------------------------------------------
-- Нормализация URL эндпоинта OpenAI Chat Completions
-- --------------------------------------------------------------------------
local function normalizeChatUrl(baseUrl)
    local url = baseUrl or "https://api.openai.com/v1"
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if not url:match("/chat/completions$") then
        if url:sub(-1) == "/" then
            url = url .. "chat/completions"
        else
            url = url .. "/chat/completions"
        end
    end
    return url
end

-- --------------------------------------------------------------------------
-- Нормализация URL эндпоинта списка моделей
-- --------------------------------------------------------------------------
local function normalizeModelsUrl(baseUrl)
    local url = baseUrl or "https://api.openai.com/v1"
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if not url:match("/models$") then
        if url:sub(-1) == "/" then
            url = url .. "models"
        else
            url = url .. "/models"
        end
    end
    return url
end

-- --------------------------------------------------------------------------
-- Основная функция запроса к LLM
-- Позиционные параметры:
--   modelSettings (table) - настройки модели:
--     baseUrl (string) - базовый URL API (например "https://api.openai.com/v1")
--     token (string) - токен авторизации
--     model (string) - обязательное название модели (например "glm-5.3-flash")
--     temperatureEnabled (boolean) - флаг передачи температуры
--     temperature (number) - значение температуры (0..2)
--   prompt (string) - текст запроса (может отсутствовать)
--   image_file (string) - абсолютный путь к файлу изображения
-- Возвращает:
--   resultText (string), isSuccess (boolean)
-- --------------------------------------------------------------------------
function OpenAIClient.chat(modelSettings, prompt, image_file)
    local baseUrl = modelSettings.baseUrl
    local token = modelSettings.token
    local model = modelSettings.model
    local temperatureEnabled = modelSettings.temperatureEnabled
    local temperature = modelSettings.temperature

    -- 1. Валидация входных данных
    if not baseUrl or baseUrl == "" then
        local errMsg = LOC('$$$/AIWI/Client/NoBaseUrl=API base URL is not set (the baseUrl parameter is required).')
        reportError(errMsg)
        return errMsg, false
    end

    if not token or token == "" then
        local errMsg = LOC('$$$/AIWI/Client/NoToken=API token for LLM access is not set. Configure it via the Setup window.')
        reportError(errMsg)
        return errMsg, false
    end

    if not model or model == "" then
        local errMsg = LOC('$$$/AIWI/Client/NoModel=LLM model is not set (the model parameter is required).')
        reportError(errMsg)
        return errMsg, false
    end

    if not image_file or image_file == "" then
        local errMsg = LOC('$$$/AIWI/Client/NoImageFile=Image file path is not set (image_file).')
        reportError(errMsg)
        return errMsg, false
    end

    -- 2. Загрузка файла изображения из файловой системы
    local rawImage, err = readFileBinary(image_file)
    if not rawImage then
        reportError(err)
        return err, false
    end

    -- 3. Кодирование изображения в Base64 Data URL
    local mimeType = getMimeType(image_file)
    local base64Data = base64Encode(rawImage)
    local dataUrl = string.format("data:%s;base64,%s", mimeType, base64Data)

    -- 4. Подготовка URL эндпоинта
    local endpointUrl = normalizeChatUrl(baseUrl)

    -- 5. Формирование тела запроса OpenAI Chat Completions
    local requestPayload = {
        model = model,
        messages = {
            {
                role = "user",
                content = {
                    {
                        type = "text",
                        text = prompt or "",
                    },
                    {
                        type = "image_url",
                        image_url = {
                            url = dataUrl,
                        },
                    },
                },
            },
        },
        stream = false,
    }

    if temperatureEnabled and temperature ~= nil then
        requestPayload.temperature = tonumber(temperature) or 1.0
    end

    local postBody = Json.encode(requestPayload)

    -- 6. Заголовки авторизации и типа контента
    local headers = {
        { field = "Content-Type", value = "application/json" },
        { field = "Authorization", value = "Bearer " .. tostring(token) },
    }

    -- 7. Выполнение HTTP POST запроса без потоковой передачи (stream = false)
    local timeout = 60
    local responseBody, responseHeaders = LrHttp.post(endpointUrl, postBody, headers, timeout)

    -- 8. Обработка сетевых ошибок
    if not responseBody then
        local errMsg = LOC('$$$/AIWI/Client/NetworkError=Network error: the LLM request returned no response (timeout or no network connection).')
        reportError(errMsg)
        return errMsg, false
    end

    -- 9. Декодирование JSON ответа
    local decoded = Json.decode(responseBody)
    local status = responseHeaders and responseHeaders.status

    if status and (status < 200 or status >= 300) then
        local apiErrorMsg = nil
        if decoded and decoded.error then
            if type(decoded.error) == "table" then
                apiErrorMsg = decoded.error.message or decoded.error.code
            else
                apiErrorMsg = tostring(decoded.error)
            end
        end
        local errMsg = LOC('$$$/AIWI/Client/ApiError=LLM API error (HTTP ^1): ^2', tostring(status), apiErrorMsg or responseBody)
        reportError(errMsg)
        return errMsg, false
    end

    if not decoded then
        local errMsg = LOC('$$$/AIWI/Client/JsonParseFailed=Failed to parse the LLM response as JSON:^n^1', tostring(responseBody):sub(1, 500))
        reportError(errMsg)
        return errMsg, false
    end

    if decoded.error then
        local errObj = decoded.error
        local errMsg = LOC('$$$/AIWI/Client/LLMError=LLM error: ^1', (type(errObj) == "table" and (errObj.message or errObj.code) or tostring(errObj)))
        reportError(errMsg)
        return errMsg, false
    end

    -- 10. Извлечение текстового результата ответа модели
    local content = nil
    if decoded.choices and decoded.choices[1] then
        local choice = decoded.choices[1]
        if choice.message and choice.message.content then
            content = choice.message.content
        elseif choice.text then
            content = choice.text
        end
    end

    if not content then
        local errMsg = LOC('$$$/AIWI/Client/NoChoices=LLM response is missing choices[1].message.content:^n^1', tostring(responseBody):sub(1, 500))
        reportError(errMsg)
        return errMsg, false
    end

    if type(content) == "table" then
        local parts = {}
        for _, block in ipairs(content) do
            if type(block) == "table" and block.text then
                table.insert(parts, block.text)
            elseif type(block) == "string" then
                table.insert(parts, block)
            end
        end
        content = table.concat(parts, "\n")
    end

    return tostring(content), true
end

-- --------------------------------------------------------------------------
-- Получение списка доступных моделей (GET baseUrl + "/models")
-- Позиционные параметры:
--   baseUrl (string) - базовый URL API (например "https://api.openai.com/v1")
--   token (string) - токен авторизации; необязательный - при отсутствии
--     (nil или пустая строка) заголовок Authorization не добавляется
-- Возвращает массив элементов { id (string), title (string) } - поля
--   id и title каждого элемента массива data ответа; при отсутствии
--   title используется сам id. Либо строку с текстовым описанием
--   ошибки (вариант определяется по type результата)
-- --------------------------------------------------------------------------
function OpenAIClient.GetModels(baseUrl, token)
    -- 1. Валидация входных данных
    if not baseUrl or baseUrl == "" then
        return LOC('$$$/AIWI/Client/NoBaseUrl=API base URL is not set (the baseUrl parameter is required).')
    end

    -- 2. Заголовки авторизации - как в OpenAIClient.chat; token
    -- необязательный: без него заголовок не добавляется
    local headers = {}
    if token and token ~= "" then
        headers[1] = {
            field = "Authorization",
            value = "Bearer " .. tostring(token),
        }
    end

    -- 3. GET-запрос списка моделей
    local endpointUrl = normalizeModelsUrl(baseUrl)
    local timeout = 60
    local responseBody, responseHeaders = LrHttp.get(endpointUrl, headers, timeout)

    -- 4. Обработка сетевых ошибок
    if not responseBody then
        return LOC('$$$/AIWI/Client/ModelsNetworkError=Network error: the models request returned no response (timeout or no network connection).')
    end

    -- 5. Декодирование JSON ответа
    local decoded = Json.decode(responseBody)
    local status = responseHeaders and responseHeaders.status

    if status and (status < 200 or status >= 300) then
        local apiErrorMsg = nil
        if decoded and decoded.error then
            if type(decoded.error) == "table" then
                apiErrorMsg = decoded.error.message or decoded.error.code
            else
                apiErrorMsg = tostring(decoded.error)
            end
        end
        return LOC('$$$/AIWI/Client/ApiError=LLM API error (HTTP ^1): ^2',
            tostring(status), apiErrorMsg or responseBody)
    end

    if not decoded then
        return LOC('$$$/AIWI/Client/JsonParseFailed=Failed to parse the LLM response as JSON:^n^1',
            tostring(responseBody):sub(1, 500))
    end

    if decoded.error then
        local errObj = decoded.error
        return LOC('$$$/AIWI/Client/LLMError=LLM error: ^1',
            (type(errObj) == "table" and (errObj.message or errObj.code) or tostring(errObj)))
    end

    if type(decoded.data) ~= "table" then
        return LOC('$$$/AIWI/Client/NoDataArray=LLM response is missing the data array:^n^1',
            tostring(responseBody):sub(1, 500))
    end

    -- 6. Список моделей: id и title каждого элемента; без title - сам id
    local models = {}
    for _, item in ipairs(decoded.data) do
        local id = item.id
        if type(id) == "string" and id ~= "" then
            local title = item.title
            if type(title) ~= "string" or title == "" then
                title = id
            end

            models[#models + 1] = {
                id = id,
                title = title,
            }
        end
    end

    return models
end

return OpenAIClient
