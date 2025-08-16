local EventListener = require("ui/widget/eventlistener")
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
local ffiutil = require("ffi/util")
local _ = require("gettext")
local Screen = Device.screen
-- Dbg:turnOn()
---@class TTS:WidgetContainer
local TTS = WidgetContainer:extend({
	name = "name of tts widget",
	fullname = _("fullname of tts widget"),
	settings = nil, -- nil means uninit widget
	prev_item = nil, -- nil means current_item is the first possible
	next_item = nil, -- nil means current_item is the last possible
	current_item = nil, -- nil means tts is not started
	current_highlight_idx = nil, -- nil means tts is not started
	widget = nil, -- nil means tts is not started
	highlight_style = {}, -- means uninit
	playing_promise = nil, -- nil means not playing rn
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
	logger.warn("TTS: onCloseDocument")
	self:stop_playing()
	self:remove_highlight()
	self:stop_tts_server()
end

function TTS:onCloseWidget()
	logger.warn("TTS: onCloseWidget")
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
	self:start_tts_server()
	self:create_highlight()
	self.next_item = self:item_next(self.current_item)
	self.prev_item = self:item_prev(self.current_item)
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
	logger.warn(
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
			logger.warn("EXTENDED TXT ACTUALLY WORKED. THIS IS IT:", extended_text, "\nIT WAS", selected_text, "\n\n\n")
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
	if item == nil then
		return nil
	end
	local next_paragraph = self.ui.document:getNextVisibleChar(item.pos1)
	if next_paragraph == nil then
		return nil
	end
	return self:item_from_xpointer(next_paragraph)
end

function TTS:item_prev(item)
	if item == nil then
		return nil
	end
	local prev_paragraph = self.ui.document:getPrevVisibleChar(item.pos0)
	if prev_paragraph == nil then
		return nil
	end
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
						text = "nothing",
						callback = function()
							logger.warn("clicked on nothing")
						end,
					},
					{
						text = "◁",
						callback = function()
							local was_playing = self.playing_promise ~= nil
							self:stop_playing()
							if self.next_item ~= nil and self.next_item.wav_promise ~= nil then
								self.next_item.wav_promise:cancel()
							end
							self.next_item = self.current_item
							self:change_highlight(self.prev_item or self.current_item)
							self.prev_item = self:item_prev(self.prev_item)
							if was_playing then
								self:start_playing()
							end
						end,
					},
					{
						text_func = function()
							if self.playing_promise ~= nil then
								return "⏸"
							end
							return "⏵"
						end,
						callback = function()
							if self.playing_promise ~= nil then
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
							local was_playing = self.playing_promise ~= nil
							self:stop_playing()
							if self.prev_item ~= nil and self.prev_item.wav_promise ~= nil then
								self.prev_item.wav_promise:cancel()
							end
							self.prev_item = self.current_item
							self:change_highlight(self.next_item or self.current_item)
							self.next_item = self:item_next(self.next_item)
							if was_playing then
								self:start_playing()
							end
						end,
					},
					{
						text = "⏹",
						callback = function()
							self:stop_playing()
							self:remove_highlight()
							self:stop_tts_server()
							UIManager:close(widget)
							self.widget = nil
							self.next_item = nil
							self.prev_item = nil
						end,
					},
				},
			},
		}),
	})
	local size = widget:getSize()
	self.widget = widget
	UIManager:show(widget, nil, nil, math.floor((screen_w - size.w) / 2), screen_h - size.h - 27)
end

---------------- simple promises like in JS because we are doing some async and I don't know better ----------

local pending = { "PENDING" }
local finished = { "FINISHED" }
local canceled = { "CANCELED" }
---@class Promise:EventListener
local Promise = EventListener:extend({
	state = pending,
	callbacks = nil, -- nil means resolved, an array (even empty) means pending
})

function Promise:resolve()
	logger.warn("resolving on this promise: ", self, "\n")
	Dbg:traceback()
	if self.callbacks == nil or self.state ~= pending then
		return
	end
	for i, callback in ipairs(self.callbacks) do
		logger.warn("resolving callback #", i)
		callback()
	end
	self.callbacks = nil
	self.state = finished
	-- local run_callback
	-- run_callback = function(idx)
	-- 	if self.callbacks == nil then
	-- 		return
	-- 	end
	-- 	local callback = self.callbacks[idx]
	-- 	if callback == nil then
	-- 		self.callbacks = nil
	-- 		return
	-- 	end
	-- 	---@type Promise?
	-- 	local p = callback()
	-- 	if p ~= nil and p.callbacks ~= nil then
	-- 		UIManager:nextTick(function()
	-- 			p:and_then(function()
	-- 				run_callback(idx + 1)
	-- 			end)
	-- 		end)
	-- 		return
	-- 	end
	-- 	UIManager:nextTick(function()
	-- 		run_callback(idx + 1)
	-- 	end)
	-- end
	--
	-- UIManager:nextTick(function()
	-- 	run_callback(1)
	-- end)
end

---@param callback fun()--:Promise?
function Promise:and_then(callback)
	logger.warn("called and_then on this promise:", self, "\n\n")
	if self.state == canceled then
		return self
	end
	if self.state == finished then
		return callback() or self
	end
	self.callbacks[#self.callbacks + 1] = callback
	return self
end

function Promise:cancel()
	self.state = canceled
	self.callbacks = nil
end

function Promise:is_pending()
	return self.state == pending
end

function Promise.wait_while(condition)
	local checker
	local promise = Promise.empty()
	checker = function()
		if condition() then
			UIManager:scheduleIn(0.2, checker)
		else
			promise:resolve()
		end
	end
	checker()
	return promise
end

function Promise.instant()
	return Promise:new({ callbacks = {}, state = finished })
end

function Promise.empty()
	return Promise:new({ callbacks = {}, state = pending })
end

-----@param other Promise
-- function Promise:join(other)
-- 	local promise = Promise.empty()
-- 	self:and_then(function()
-- 		other:and_then(function()
-- 			promise:resolve()
-- 		end)
-- 	end)
-- 	return promise
-- end

function Promise:wrap()
	local promise = Promise.empty()
	promise.WRAP_MARK = self
	self:and_then(function()
		logger.warn("resolving going outer")
		promise:resolve()
	end)
	return promise
end

------------------ AUDIO MODULE -------------------

function TTS:play(item)
	Dbg.dassert(item.wav_promise == nil and item.wav ~= nil, "tried to play an item before creating the wav file")
	logger.warn("playing item", item)
	local process = io.popen("plugins/TTS.koplugin/play " .. item.wav, "r")
	if process == nil then
		return
	end
	local promise = Promise.empty()
	promise = Promise.wait_while(function()
		local a = ffiutil.getNonBlockingReadSize(process)
		logger.err(a)
		return promise:is_pending() and a == 0
	end):and_then(function()
		logger.warn("playing endend, promise is ", promise)
		-- local _ = process:read("*a")
		-- process:close()
	end)
	promise.MARK0 = "play watcher"
	promise = promise:wrap()

	self.playing_promise = promise
	self.playing_promise.MARK = "the tts:play monitoring promise"
	return promise
end

function TTS:stop_tts_server() end

function TTS:start_tts_server() end

---@return Promise
function TTS:ensure_wav_on_item(item, wav_name)
	if item.wav ~= nil then
		if item.wav_promise == nil then
			return Promise.instant()
		end
		return item.wav_promise
	end

	item.wav = wav_name
	local sub = function()
		local process = io.popen("plugins/TTS.koplugin/create_wav " .. wav_name, "w")
		if process == nil then
			return
		end
		process:write(item.text)
		process:close() -- this is blocking, but we need it to write EOF for the script to start, so I just ran it in a separate thread
		-- TODO: try to resolve from here
	end
	local pid = ffiutil.runInSubProcess(sub)
	local promise = Promise.wait_while(function()
		return not ffiutil.isSubProcessDone(pid)
	end):and_then(function()
		item.wav_promise = nil
		logger.warn("ENDED WAV GENERATION, c is ", promise, "\n\n")
	end)

	promise.MARK0 = "ensure wav watcher"
	promise = promise:wrap()
	item.wav_promise = promise
	promise.MARK = "TTS:ENSURE_WAV_ON_ITEM"
	return promise
end

function TTS:stop_playing()
	if self.playing_promise ~= nil then
		logger.warn("current promise is ", self.playing_promise, " CANCELING IT\n\n")
		self.playing_promise:cancel()
		self.playing_promise = nil
		local process = os.execute("plugins/TTS.koplugin/stop_playing")
	end
end



function TTS:start_playing()
	local choose_name = function()
		local candidates = {
			"one.wav",
			"two.wav",
			"three.wav",
		}
		for _, candidate in ipairs(candidates) do
			if
				(self.current_item == nil or self.current_item.wav ~= candidate)
				and (self.next_item == nil or self.next_item.wav ~= candidate)
				and (self.prev_item == nil or self.prev_item.wav ~= candidate)
			then
				return candidate
			end
		end
		return "fallback.wav"
	end

	local play_once
	play_once = function()
		logger.warn("starting playing")
		if self.next_item == nil then
			-- We hit the end of the book in tts mode
			self:stop_playing()
			UIManager:close(self.widget)
			self:show_widget()
			return
		end
		local wav_for_the_next = self:ensure_wav_on_item(self.next_item, choose_name())
		self:play(self.current_item):and_then(function()
			logger.err("DONE!!!!!!")
			-- self.prev_item = self.current_item
			-- self:change_highlight(self.next_item)
			-- self.next_item = self:item_next(self.next_item)
			-- wav_for_the_next:and_then(play_once)
		end)
	end
	self.playing_promise = self:ensure_wav_on_item(self.current_item, choose_name())
	self.playing_promise.MARK2 = "the outer ensure_wav_on_item"
	self.playing_promise:and_then(function()
		play_once()
	end)
end

return TTS
