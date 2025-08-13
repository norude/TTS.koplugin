local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ImageWidget = require("ui/widget/imagewidget")
local Dbg = require("dbg")
local logger = require("logger")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local util = require("util")
local _ = require("gettext")

Dbg:turnOn()

local TTS = WidgetContainer:extend({
    name = "name of tts widget",
    fullname = _("fullname of tts widget"),
    settings = nil,
    is_running = false,
    highlight_style = {},

})

function TTS:init()
    if not self.settings then self:readSettingsFile() end
    self.ui.menu:registerToMainMenu(self)
end



function TTS:readSettingsFile()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/tts.lua")
    local highlight_style = self.settings:child("highlight_style")
    self.highlight_style.drawer = highlight_style:readSetting("drawer", "lighten")
    self.highlight_style.color = highlight_style:readSetting("color", "gray")

    self.settings:flush()
end


function TTS:addToMainMenu(menu_items)
    menu_items.tts = {
        text = _("TTS stuff"),
        sorting_hint = "main",
        sub_item_table = {
            {
                text = _("Tap to start tts"),
                keep_menu_open = true,
                callback = function()
                    self:start_tts_mode()
                end,
            },
        },
    }
end


function TTS:start_tts_mode()
    UIManager:show(InfoMessage:new({ text = _("starting tts mode...") }))
    -- local dummy_image = ImageWidget:new{
    --     file = "resources/koreader.png",
    -- }
    -- -- the image will be painted on all book pages
    -- self.view:registerViewModule('dummaaas_image', dummy_image)
    self.is_running = true
    self:create_highlight()
end

function TTS:create_highlight(selected_text)
        local page = self.ui.document:getFirstPageInFlow(0);
        logger.dbg("document:", self.ui.document)
        logger.dbg("currentpos:", self.ui.document:getCurrentPos())
        logger.dbg("currentpos:", self.ui.document:getTextFromPositions({x=0,y=0},{x=0,y=0}))
        logger.dbg("THIS IS THE FIRST PAGE:", page)
        local selected_text
        local extend_to_sentence = true
        local pg_or_xp
        if self.ui.rolling then
            if extend_to_sentence then
                local extended_text = self.ui.document:extendXPointersToSentenceSegment(selected_text.pos0, selected_text.pos1)
                if extended_text then
                    selected_text = extended_text
                end
            end
            pg_or_xp = selected_text.pos0
        else
            pg_or_xp =selected_text.pos0.page
        end

    local item = {
        page = self.ui.paging and selected_text.pos0.page or selected_text.pos0,
        pos0 = selected_text.pos0,
        pos1 = selected_text.pos1,
        text = util.cleanupSelectedText(selected_text.text),
        drawer = self.highlight_style.drawer,
        color = self.highlight_style.color,
        chapter = self.ui.toc:getTocTitleByPage(pg_or_xp),
    }
    if self.ui.paging then
        item.pboxes = self.selected_text.pboxes
        item.ext = self.selected_text.ext
    end
    local index = self.ui.annotation:addItem(item)
    return index
end


return TTS
