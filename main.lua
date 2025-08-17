local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local DataStorage = require("datastorage")
local Dbg = require("dbg")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local EventListener = require("ui/widget/eventlistener")
local FrameContainer = require("ui/widget/container/framecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local Screen = Device.screen
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local ffiutil = require("ffi/util")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local util = require("util")
Dbg:turnOn()
---@class TTS:WidgetContainer
local TTS = WidgetContainer:extend({
	name = "name of tts widget",
	fullname = _("fullname of tts widget"),
	settings = nil, -- nil means uninit widget
	luasettings = nil, -- nil means uninit widget
	prev_item = nil, -- nil means current_item is the first possible
	next_item = nil, -- nil means current_item is the last possible
	current_item = nil, -- nil means tts is not started
	current_highlight_idx = nil, -- nil means tts is not started
	widget = nil, -- nil means tts is not started
	playing_promise = nil, -- nil means not playing rn
	highlight_style = {}, -- means uninit
})

---@type ReaderUI
TTS.ui = nil
---@type ReaderView
TTS.view = nil
function TTS:init()
	if not self.luasettings then
		self:readSettingsFile()
	end
	self.ui.menu:registerToMainMenu(self)
end

function TTS:readSettingsFile()
	self.luasettings = LuaSettings:open(DataStorage:getSettingsDir() .. "/tts.lua")
	self.settings = {}
	self.settings.drawer = self.luasettings:readSetting("highlight_style.drawer", "lighten")
	self.settings.color = self.luasettings:readSetting("color", "gray")
	self.settings.always_follow = self.luasettings:readSetting("always_follow", true)
	self.settings.hostname = self.luasettings:readSetting("hostname", "localhost:5000")
	self.settings.server_extra_args = self.luasettings:readSetting("server_extra_args", {
		length_scale = 1,
	})
	self:settings_flush()
end

function TTS:settings_flush()
	self.luasettings:flush()
end

function TTS:onCloseDocument()
	logger.warn("TTS: onCloseDocument")
	self:stop_playing()
	self:remove_highlight()
	self:stop_tts_server()
end

function TTS:onCloseWidget()
	logger.warn("TTS: onCloseWidget")
	self:settings_flush()
end

function TTS:addToMainMenu(menu_items)
	menu_items.tts = {
		sorting_hint = "main",
		-- text = _("TTS stuff"),
		-- sub_item_table = {
		-- 	{
		text = _("Start TTS Mode"),
		callback = function()
			self:start_tts_mode()
		end,
		-- },
		-- },
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
	self.ui:handleEvent(Event:new("GotoXPointer", self.current_item.pos0))
end

function TTS:change_highlight(item)
	self.ui.annotation.annotations[self.current_highlight_idx] = item
	self.ui:handleEvent(
		Event:new("AnnotationsModified", { item, self.current_item, index_modified = self.current_highlight_idx })
	)
	UIManager:setDirty(self.dialog, "ui")
	logger.info("highlighting the ", item)
	self.current_item = item
	if
		self.settings.always_follow
		or not self.ui.document:isXPointerInCurrentPage(self.current_item.pos0)
		or not self.ui.document:isXPointerInCurrentPage(self.current_item.pos1)
	then
		self.ui:handleEvent(Event:new("GotoXPointer", self.current_item.pos0))
	end
end

function TTS:remove_highlight()
	self.ui.bookmark:removeItemByIndex(self.current_highlight_idx)
	UIManager:setDirty(self.dialog, "ui")
	self.current_highlight_idx = nil
	self.current_item = nil
end

function TTS:xpointer_start(xpointer)
	local wrap = self.ui.document.configurable.text_wrap
	self.ui.document.configurable.text_wrap = 0
	local page = self.ui.document:getPageFromXPointer(xpointer)
	local prefix = xpointer:match("^(.*)%.[^%.]*$")
	if not prefix then
		prefix = xpointer
	end
	local start = prefix .. ".0"
	if self.view.view_mode == "page" and page ~= self.ui.document:getPageFromXPointer(start) then
		return self.ui.document:getPageXPointer(page)
	end
	self.ui.document.configurable.text_wrap = wrap
	return start
end

function TTS:xpointer_end(xpointer)
	local wrap = self.ui.document.configurable.text_wrap
	self.ui.document.configurable.text_wrap = 0
	local page = self.ui.document:getPageFromXPointer(xpointer)
	local prefix = xpointer:match("^(.*)%.[^%.]*$")
	if not prefix then
		prefix = xpointer
	end
	prefix = prefix .. "."
	local text = self.ui.document:getTextFromXPointer(xpointer)
	local text_len = text:len()
	local max = text_len * 2
	local min = 0
	while min < max do
		local mid = math.floor((min + max) / 2)
		logger.warn("Guessed ", mid, "max is ", max, " min is", min)
		if
			select("#", self.ui.document:getTextFromXPointer(prefix .. mid)) ~= 0
			and (self.view.view_mode ~= "page" or page >= self.ui.document:getPageFromXPointer(prefix .. mid))
		then
			logger.warn("was correct")
			min = mid + 1
		else
			logger.warn("was too high")
			max = mid
		end
	end
	self.ui.document.configurable.text_wrap = wrap
	return prefix .. min - 1
end

function TTS:item_from_xpointer(xpointer)
	local selected_text = {
		pos0 = self:xpointer_start(xpointer),
		pos1 = self:xpointer_end(xpointer),
	}
	local text = self.ui.document:getTextFromXPointers(selected_text.pos0, selected_text.pos1)
	local item = {
		page = self.ui.paging and selected_text.pos0.page or selected_text.pos0,
		pos0 = selected_text.pos0,
		pos1 = selected_text.pos1,
		text = util.cleanupSelectedText(text),
		drawer = self.settings.drawer,
		color = self.settings.color,
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
							logger.warn("nothing")
						end,
					},
					{
						text = "◁",
						callback = function()
							local was_playing = self.playing_promise ~= nil
							self:stop_playing()
							if self.next_item ~= nil and self.next_item.wav_promise ~= nil then
								self.next_item.wav_promise:cancel() -- FIXME: we need to actually kill someone here
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
								self.prev_item.wav_promise:cancel() -- FIXME: we need to actually kill someone here
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

---@class Promise:EventListener
local Promise = EventListener:extend({
	callbacks = nil, -- nil means resolved, an array (even empty) means pending
	on_cancel = nil,
})

function Promise:resolve()
	if self.callbacks == nil then
		return
	end
	for i, callback in ipairs(self.callbacks) do
		callback()
	end
	self.callbacks = nil
end

---@param callback fun()--:Promise?
function Promise:and_then(callback)
	if self.callbacks == nil then
		return callback() or self
	end
	self.callbacks[#self.callbacks + 1] = callback
	return self
end

function Promise:cancel()
	self.callbacks = nil
	self.and_then = function()
		return self
	end
	self.resolve = function() end
	if self.on_cancel ~= nil then
		self:on_cancel()
	end
	self.on_cancel = nil
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
	return Promise:new({ callbacks = nil })
end

function Promise.empty()
	return Promise:new({ callbacks = {} })
end

function Promise:wrap()
	local promise = Promise.empty()
	self:and_then(function()
		promise:resolve()
	end)
	return promise
end

------------------ AUDIO MODULE -------------------

function TTS:play(item)
	Dbg.dassert(item.wav_promise == nil and item.wav ~= nil, "tried to play an item before creating the wav file")
	-- logger.warn("playing item", item)
	local process = io.popen("plugins/TTS.koplugin/play " .. item.wav, "r")
	if process == nil then
		return
	end
	local promise = Promise.empty()
	promise = Promise.wait_while(function()
		return promise.callbacks ~= nil and ffiutil.getNonBlockingReadSize(process) == 0
	end)
		:and_then(function()
			local _ = process:read("*a")
			process:close()
		end)
		:wrap()

	promise.on_cancel = function()
		os.execute("plugins/TTS.koplugin/stop_playing")
	end
	return promise
end

function TTS:start_tts_server() end

function TTS:request_server(body)
	local result = {}
	local _, code = http.request({
		method = "POST",
		url = "http://" .. self.settings.hostname,
		source = ltn12.source.string(body),
		headers = {
			["Content-Length"] = #body,
			["Content-Type"] = "application/json",
		},
		sink = ltn12.sink.table(result),
	})
	return code, result
end

function TTS:stop_tts_server() end

---@return Promise
function TTS:ensure_wav_on_item(item, wav_name)
	if item.wav ~= nil then
		if item.wav_promise == nil then
			return Promise.instant()
		end
		return item.wav_promise
	end

	item.wav = wav_name
	local download_thread = function()
		local body = rapidjson.encode({
			text = item.text,
		})
		body = self.extend(body, self.settings.server_extra_args)
		local code, wav_table = self:request_server(body)
		if code == 200 then
			ltn12.pump.all(
				ltn12.source.table(wav_table),
				ltn12.sink.file(io.open("plugins/TTS.koplugin/" .. wav_name, "w"))
			)
		end
	end
	local pid = ffiutil.runInSubProcess(download_thread)
	local promise = Promise.wait_while(function()
		return not ffiutil.isSubProcessDone(pid)
	end)
		:and_then(function()
			item.wav_promise = nil
		end)
		:wrap()
	promise.on_cancel = function()
		ffiutil.terminateSubProcess(pid)
	end
	item.wav_promise = promise
	return promise
end

function TTS:stop_playing()
	if self.playing_promise ~= nil then
		-- logger.warn("current promise is ", self.playing_promise, " CANCELING IT\n\n")
		self.playing_promise:cancel()
		self.playing_promise = nil
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
		if self.next_item == nil then
			-- We hit the end of the book in tts mode
			self:stop_playing()
			UIManager:close(self.widget)
			self:show_widget()
			return
		end
		local wav_for_the_next = self:ensure_wav_on_item(self.next_item, choose_name())
		self.playing_promise = self:play(self.current_item)
		self.playing_promise:and_then(function()
			self.prev_item = self.current_item
			self:change_highlight(self.next_item)
			self.next_item = self:item_next(self.next_item)
			wav_for_the_next:and_then(play_once)
		end)
	end
	self.playing_promise = self:ensure_wav_on_item(self.current_item, choose_name())
	self.playing_promise:and_then(function()
		play_once()
	end)
end

return TTS
