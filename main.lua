local Event = require("ui/event")
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
	current_item = nil,
	current_highlight_idx = nil,
	highlight_style = {},
})

function TTS:init()
	if not self.settings then
		self:readSettingsFile()
	end
	self.ui.menu:registerToMainMenu(self)
end

function TTS:readSettingsFile()
	self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/tts.lua")
	local highlight_style = self.settings:child("highlight_style")
	self.highlight_style.drawer = highlight_style:readSetting("drawer", "lighten")
	self.highlight_style.color = highlight_style:readSetting("color", "gray")

	self.settings:flush()
end

function TTS:onCloseDocument()
	logger.dbg("TTS: onCloseDocument")
	self:remove_highlight()
end

function TTS:onCloseWidget()
	logger.dbg("TTS: onCloseWidget")
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
			{
				text = _("prev paragraph"),
				keep_menu_open = true,
				callback = function()
					self:change_highlight(self:item_prev(self.current_item))
				end,
			},
			{
				text = _("next paragraph"),
				keep_menu_open = true,
				callback = function()
					self:change_highlight(self:item_next(self.current_item))
				end,
			},
			{
				text = _("delete highlight"),
				keep_menu_open = true,
				callback = function()
					self:remove_highlight()
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
	self:create_highlight()
end

function TTS:create_highlight()
	local xpointer = self.ui.document:getPageXPointer(self.ui.document:getCurrentPage(true))
	local item = self:item_from_xpointer(xpointer)

	local index = self.ui.annotation:addItem(item)

	self.current_item = item
	self.current_highlight_idx = index

	-- flush
	self.view.footer:maybeUpdateFooter()
	self.ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = 1, index_modified = index }))
end

function TTS:change_highlight(item)
	self.ui.annotation.annotations[self.current_highlight_idx] = item
	logger.dbg("modified, I hope these are diffrent. Item:\n", item, "\nAnd self.current_item:\n", self.current_item)
	self.ui:handleEvent(
		Event:new("AnnotationsModified", { item, self.current_item, index_modified = self.current_highlight_idx })
	)
	UIManager:setDirty(self.dialog, "ui")
	self.current_item = item
	if not self.ui.document:isXPointerInCurrentPage(item.pos0) then
		self.ui:handleEvent(Event:new("GotoXPointer", item.pos0))
	end
end

function TTS:remove_highlight()
	self.ui.bookmark:removeItemByIndex(self.current_highlight_idx)
	UIManager:setDirty(self.dialog, "ui")
	self.current_highlight_idx = nil
	self.current_item = nil
end

function TTS:xpointer_start(xpointer)
	-- TODO: if xpointer and xpointer_start(xpointer) are on diffrent pages, set xpointer_start(xpointer) to the start of the page instead
	local prefix = xpointer:match("^(.*)%.[^%.]*$")
	if not prefix then
		prefix = xpointer
	end
	return prefix .. ".0"
end

function TTS:xpointer_end(xpointer)
	-- TODO: if xpointer and xpointer_end(xpointer) are on diffrent pages, set xpointer_end(xpointer) to the end of the page instead
	local prefix = xpointer:match("^(.*)%.[^%.]*$")
	if not prefix then
		prefix = xpointer
	end
	prefix = prefix .. "."
	local text = self.ui.document:getTextFromXPointer(xpointer)
	local text_len = text:len()
	local idx = text_len
	-- This is VERY hacky, but the xpointer at prefix..text_len overshoots, so we just find the last one that works
	-- FIXME: This is a task for a binary search
	while select("#", self.ui.document:getTextFromXPointer(prefix .. idx)) == 0 do
		if idx < 0 then -- Hopefully will never trigger
			idx = text_len * 2
		end
		idx = idx - 1
	end
	logger.dbg(
		"Found the end of the xpointer. \n\n\n Text_len was ",
		text_len,
		"But actual is",
		idx,
		"\n\t THE DIFFRENCE IS ",
		text_len - idx,
		"\n For reference, this is the text:\n",
		text
	)
	return prefix .. idx
end

function TTS:item_from_xpointer(xpointer)
	local selected_text = {
		pos0 = self:xpointer_start(xpointer),
		pos1 = self:xpointer_end(xpointer),
	}
	local pg_or_xp
	if self.ui.rolling then
		local extended_text = self.ui.document:extendXPointersToSentenceSegment(selected_text.pos0, selected_text.pos1)
		if extended_text then
			logger.dbg("EXTENDED TXT ACTUALLY WORKED. THIS IS IT:", extended_text, "\nIT WAS", selected_text, "\n\n\n")
			selected_text = extended_text
		end
		pg_or_xp = selected_text.pos0
	else
		pg_or_xp = selected_text.pos0.page
	end
	local text = self.ui.document:getTextFromXPointer(selected_text.pos0)
	local item = {
		page = self.ui.paging and selected_text.pos0.page or selected_text.pos0,
		pos0 = selected_text.pos0,
		pos1 = selected_text.pos1,
		text = util.cleanupSelectedText(text),
		drawer = self.highlight_style.drawer,
		color = self.highlight_style.color,
		chapter = self.ui.toc:getTocTitleByPage(pg_or_xp),
	}
	return item
end

function TTS:item_next(item)
	local next_paragraph = self.ui.document:getNextVisibleChar(item.pos1)
	return self:item_from_xpointer(next_paragraph)
end

function TTS:item_prev(item)
	local prev_paragraph = self.ui.document:getPrevVisibleChar(item.pos0)
	return self:item_from_xpointer(prev_paragraph)
end

return TTS
