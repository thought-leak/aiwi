local LOC = LOC

local menuItems = {
    {
        title = LOC('$$$/AIWI/Menu/IdentifySubject=Identify subject'),
        file = "identify_ai.lua",
    },
}

return {
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 10.0,
    LrToolkitIdentifier = 'com.adobe.lightroom.lrtags.plugin',
    LrPluginName = LOC('$$$/AIWI/PluginName=AIWI'),
    LrAlsoUseBuiltInTranslations=true,

    -- В меню Library -> Plug-in Extras (доступно только в модуле «Библиотека»)
    LrLibraryMenuItems = menuItems,

    -- В меню File -> Plug-in Extras (доступно глобально во всех модулях, включая Develop)
    LrExportMenuItems = menuItems,
}
