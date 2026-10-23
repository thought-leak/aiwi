local LOC = LOC

local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'

local AnswerWindow = {}

-- Отображает модальное окно с ответом модели (для просмотра).
-- title - заголовок окна, text - многострочный текст ответа.
-- Окно ничего не возвращает: закрывается только кнопкой "Close".
function AnswerWindow.show(title, text)
    LrFunctionContext.callWithContext("answer_window", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        props.answer = text or ""

        -- Содержимое диалога
        local contents = f:column {
            spacing = f:control_spacing(),
            bind_to_object = props,
            fill_horizontal = 1,
            width = 500,

            -- Многострочное поле с ответом (8 строк). Поле включено
            -- (можно выделять текст и копировать), но любые изменения
            -- отклоняются transform'ом привязки - текст недоступен
            -- для редактирования
            f:edit_field {
                value = LrView.bind {
                    key = "answer",
                    transform = function(value, fromModel)
                        if fromModel then
                            return value
                        end
                        -- Изменение из поля ввода отклоняем - возвращаем
                        -- текущее значение модели
                        return props.answer
                    end,
                },
                height_in_lines = 8,
                fill_horizontal = 1,
                wraps = true,

                -- Недокументированное свойство edit_field (LR SDK):
                -- без него Enter/Return активировал бы кнопку "Close"
                -- при выделении текста для копирования. С ним Enter
                -- в многострочном поле не закрывает окно.
                allow_newlines = true,
            },
        }

        -- Единственная кнопка диалога - "Close" (закрывает окно)
        LrDialogs.presentModalDialog({
            title = title,
            contents = contents,
            cancelVerb = LOC('$$$/AIWI/Answer/CloseButton=Close'),
        })
    end)
end

return AnswerWindow
