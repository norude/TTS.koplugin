local Blitbuffer = require("ffi/blitbuffer")
local InputContainer = require("ui/widget/container/inputcontainer")
local ButtonTable = require("ui/widget/buttontable")
local DataStorage = require("datastorage")
local Dbg = require("dbg")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen
Dbg:turnOn()

local TTS = WidgetContainer:extend({
	name = "name of tts widget",
	fullname = _("fullname of tts widget"),
	settings = nil,
	current_item = nil,
	current_highlight_idx = nil,
	highlight_style = {},
	is_playing = false,
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
	self:stop_playing()
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
				text = _("Start TTS"),
				callback = function()
					self:start_tts_mode()
				end,
			},
		},
	}
end

function TTS:start_tts_mode()
	self:create_highlight()
	self:show_widget()
end

---------------- highlight module --------------

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

------------------------- THE WIDGET -------------------------

function TTS:show_widget()
	local screen_w = Screen:getWidth()
	local screen_h = Screen:getHeight()
	--     file = "resources/koreader.png",
	-- }
	-- -- the image will be painted on all book pages
	local widget
	widget = FrameContainer:new({
		radius = Size.radius.window,
		bordersize = Size.border.window,
		padding = 0,
		margin = 0,
		background = Blitbuffer.COLOR_WHITE,
		ButtonTable:new({
			buttons = {
				{
					{
						text = "◁",
						callback = function()
							self:change_highlight(self:item_prev(self.current_item))
						end,
					},
					{
						text_func = function()
							if self.is_playing then
								return "⏸"
							end
							return "⏵"
						end,
						callback = function()
							if self.is_playing then
								self:stop_playing()
							else
								self:start_playing()
							end
							UIManager:close(widget)
							self:show_widget()
						end,
					},
					{
						text = "▷",
						callback = function()
							self:change_highlight(self:item_next(self.current_item))
						end,
					},
					{
						text = "⏹",
						callback = function()
							self:stop_playing()
							self:remove_highlight()
							UIManager:close(widget)
						end,
					},
				},
			},
		}),
	})
	local size = widget:getSize()
	UIManager:show(widget, nil, nil, math.floor((screen_w - size.w) / 2), screen_h - size.h - 27)
end

------------------ AUDIO MODULE -------------------

function TTS:stop_playing()
	self.is_playing = false
end

function TTS:start_playing()
	self.is_playing = true
end

return TTS
