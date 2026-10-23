local LOC = LOC

local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'

local PromptWindow = {}

-- Отображает модальное окно предпросмотра сформированного промпта.
-- prompt - результат PromptBuilder.Build (шаблон с подставленными
--   метаданными фото).
-- Окно содержит только одно большое нередактируемое многострочное
-- текстовое поле (10 строк) и кнопку "Close"; возврат - nil, окно
-- ничего не выбирает и ничего не меняет.
-- Поле включено: текст можно выделять и копировать, но любые правки
-- отклоняются transform'ом привязки
function PromptWindow.show(prompt)
    LrFunctionContext.callWithContext("prompt_window",
        function(context)
            local f = LrView.osFactory()
            local props = LrBinding.makePropertyTable(context)

            props.text = prompt or ""

            local contents = f:column {
                spacing = f:control_spacing(),
                bind_to_object = props,
                fill_horizontal = 1,
                width = 600,

                f:edit_field {
                    value = LrView.bind {
                        key = "text",
                        transform = function(value, fromModel)
                            if fromModel then
                                return value
                            end
                            -- Изменение из поля ввода отклоняем всегда:
                            -- поле только для просмотра
                            return props.text
                        end,
                    },
                    height_in_lines = 10,
                    wraps = true,
                    fill_horizontal = 1,
                    -- Enter вставляет перенос строки вместо нажатия
                    -- кнопки по умолчанию (вставка отклонится transform'ом)
                    allow_newlines = true,
                },
            }

            LrDialogs.presentModalDialog({
                title = LOC('$$$/AIWI/Prompt/Title=Prompt preview'),
                contents = contents,
                cancelVerb = LOC('$$$/AIWI/Prompt/CloseButton=Close'),
                resizable = "horizontally",
            })
        end)
end

return PromptWindow
