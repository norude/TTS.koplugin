local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local EventListener = require("ui/widget/eventlistener")
local FrameContainer = require("ui/widget/container/framecontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Screen = Device.screen
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local ffiutil = require("ffi/util")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local util = require("util")
---@class TTS:WidgetContainer
local TTS = WidgetContainer:extend({
	name = "name of tts widget",
	fullname = _("fullname of tts widget"),
	settings = nil,           -- nil means uninit widget
	luasettings = nil,        -- nil means uninit widget
	prev_item = nil,          -- nil means current_item is the first possible
	next_item = nil,          -- nil means current_item is the last possible
	current_item = nil,       -- nil means tts is not started
	current_highlight_idx = nil, -- nil means tts is not started
	widget = nil,             -- nil means tts is not started
	playing_promise = nil,    -- nil means not playing rn
	highlight_style = {},     -- means uninit
})

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
	self.settings.hostname = self.luasettings:readSetting("hostname", "localhost:5000")
	self.settings.server_extra_args = self.luasettings:readSetting("server_extra_args", {})
	self:settings_flush()
end

function TTS:settings_flush()
	self.luasettings:saveSetting("highlight_style.drawer", self.settings.drawer)
	self.luasettings:saveSetting("color", self.settings.color)
	self.luasettings:saveSetting("hostname", self.settings.hostname)
	self.luasettings:saveSetting("server_extra_args", self.settings.server_extra_args)
	self.luasettings:flush()
	if self.current_item ~= nil then
		self:change_highlight(self.current_item)
		for _, item in ipairs({ self.prev_item, self.current_item, self.next_item }) do
			if item.wav ~= nil then
				item.wav = nil
				if item.wav_promise ~= nil then
					item.wav_promise:cancel()
				end
			end
		end
	end
end

function TTS:onCloseDocument()
	logger.dbg("TTS: onCloseDocument")
	self:stop_tts_mode()
end

function TTS:onCloseWidget()
	logger.dbg("TTS: onCloseWidget")
	self:settings_flush()
end

function TTS:addToMainMenu(menu_items)
	if not self.ui.document then -- only add in reader view
		return
	end
	menu_items.tts_plugin = {
		sorting_hint = "typeset",
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
	self:create_highlight()
	self.next_item = self:item_next(self.current_item)
	self.prev_item = self:item_prev(self.current_item)
	self:show_widget()
end

function TTS:stop_tts_mode()
	self:stop_playing()
	self:remove_highlight()
	self.next_item = nil
	self.prev_item = nil
	UIManager:close(self.widget)
	self.widget = nil
end

---------------- highlight module --------------

function TTS:create_highlight()
	local xpointer = self.ui.document:getPageXPointer(self.ui.document:getCurrentPage(true))
	-- make sure that the we highlight only text
	local s = self.ui.document:getNextVisibleChar(xpointer)
	if s ~= nil then
		xpointer = s
	end
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
	item.drawer = self.settings.drawer
	item.color = self.settings.color
	self.ui.annotation.annotations[self.current_highlight_idx] = item
	self.ui:handleEvent(
		Event:new("AnnotationsModified", { item, self.current_item, index_modified = self.current_highlight_idx })
	)
	UIManager:setDirty(self.dialog, "ui")
	self.current_item = item
	if
		self.view.view_mode ~= "page"
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
	local max = self.ui.document:getTextFromXPointer(xpointer):len() * 2
	local min = 1
	while min < max do
		local mid = math.floor((min + max) / 2)
		if
			select("#", self.ui.document:getTextFromXPointer(prefix .. mid)) ~= 0
			and (self.view.view_mode ~= "page" or page >= self.ui.document:getPageFromXPointer(prefix .. mid))
		then
			min = mid + 1
		else
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
	if text ~= nil then
		text = util.cleanupSelectedText(text)
	end
	local item = {
		page = self.ui.paging and selected_text.pos0.page or selected_text.pos0,
		pos0 = selected_text.pos0,
		pos1 = selected_text.pos1,
		text = text,
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
						text = "⚙",
						callback = function()
							if self.playing_promise ~= nil then
								self:stop_playing()
								UIManager:close(widget)
								self:show_widget()
							end
							self:show_settings()
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
							self:stop_tts_mode()
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

local function pairsByKeys(t, f)
	local a = {}
	for n in pairs(t) do
		table.insert(a, n)
	end
	table.sort(a, f)
	local i = 0          -- iterator variable
	local iter = function() -- iterator function
		i = i + 1
		if a[i] == nil then
			return nil
		else
			return a[i], t[a[i]]
		end
	end
	return iter
end
function TTS:show_settings()
	local settings_dialog
	settings_dialog = ButtonDialog:new({
		title = _("TTS settings"),
		buttons = {
			{
				{
					text = _("Speed"),
					callback = function()
						UIManager:show(SpinWidget:new({
							value = self.settings.server_extra_args.length_scale,
							value_min = 0.01,
							value_max = 3,
							precision = "%.2f",
							value_step = 0.01,
							value_hold_step = 0.1,
							default_value = 1,
							title_text = _("Length scale"),
							info_text = _("A value of 2 means that audio will take twice the time to play"),
							callback = function(spin)
								self.settings.server_extra_args.length_scale = spin.value
								self:settings_flush()
							end,
						}))
					end,
				},
				{
					text = _("Volume"),
					callback = function()
						UIManager:show(SpinWidget:new({
							value = self.settings.server_extra_args.volume,
							value_min = 0,
							value_max = 1,
							precision = "%.2f",
							value_step = 0.01,
							value_hold_step = 0.1,
							default_value = 0.8,
							title_text = _("Volume"),
							info_text = _("Select volume from 0 to 1"),
							callback = function(spin)
								self.settings.server_extra_args.volume = spin.value
								self:settings_flush()
							end,
						}))
					end,
				},
			},
			{
				{
					text = _("TTS server URL"),
					callback = function()
						UIManager:show(InputDialog:new({
							title = _("Change TTS server URL"),

							input_type = "text",
							input = self.settings.hostname,
							description = _("Don't add 'http://'"),
							save_callback = function(new_hostname)
								self.settings.hostname = new_hostname
								self:settings_flush()
							end,
						}))
					end,
				},
				{
					text = _("Voice"),
					callback = function()
						local voices = self:server_get_voices()
						if voices == nil then
							UIManager:show(InfoMessage:new({ text = _("Could not fetch availible voices") }))
							return
						end
						local upper_widget
						local buttons = { {} }
						for locale, cluster in pairsByKeys(voices) do
							local last = buttons[#buttons]
							if #last >= 6 then
								last = {}
								table.insert(buttons, last)
							end
							table.insert(last, {
								text = locale,
								callback = function()
									local voice_buttons = {}
									for _, voice in ipairs(cluster) do
										table.insert(voice_buttons, {
											{
												text = voice,
												checked = voice == self.settings.server_extra_args.voice,
												callback = function()
													self.settings.server_extra_args.voice = voice
													self:settings_flush()
													UIManager:close(UIManager:getTopmostVisibleWidget())
												end,
											},
										})
									end
									table.insert(voice_buttons, {
										{
											text = _("Close"),
											callback = function()
												UIManager:close(UIManager:getTopmostVisibleWidget())
												UIManager:show(upper_widget())
											end,
										},
									})
									UIManager:close(UIManager:getTopmostVisibleWidget())
									UIManager:show(ButtonDialog:new({
										text = _("Select voice"),
										shrink_unneeded_width = true,
										buttons = voice_buttons,
									}))
								end,
							})
						end
						table.insert(buttons, {
							{
								text = _("Close"),
								callback = function()
									UIManager:close(UIManager:getTopmostVisibleWidget())
								end,
							},
						})
						upper_widget = function()
							return ButtonDialog:new({
								title = self.settings.server_extra_args.voice
									and T(_('Current voice is "%1"'), self.settings.server_extra_args.voice)
									or _("Select voice"),
								buttons = buttons,
								shrink_unneeded_width = true,
							})
						end
						UIManager:show(upper_widget())
					end,
				},
			},
			{
				{
					text = _("Highlight color"),
					callback = function()
						self.ui.highlight:showHighlightColorDialog(function(a)
							self.settings.color = a
							self:settings_flush()
							UIManager:close(UIManager:getTopmostVisibleWidget())
						end, { color = self.settings.color })
					end,
				},

				{
					text = _("Highlight style"),
					callback = function()
						self.ui.highlight:showHighlightStyleDialog(function(a)
							self.settings.drawer = a
							self:settings_flush()
						end)
					end,
				},
			},
			{
				{
					text = _("Close"),
					callback = function()
						settings_dialog:onClose()
						UIManager:close(settings_dialog)
					end,
				},
			},
		},
	})

	UIManager:show(settings_dialog)
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
	for _, callback in ipairs(self.callbacks) do
		callback()
	end
	self.callbacks = nil
end

---@param callback fun()
function Promise:add_callback(callback)
	if self.callbacks == nil then
		callback()
		return
	end
	self.callbacks[#self.callbacks + 1] = callback
end

function Promise:cancel()
	self.callbacks = nil
	self.add_callback = function() end
	self.resolve = function() end
	if self.on_cancel ~= nil then
		self:on_cancel()
	end
	self.on_cancel = nil
end

function Promise.wait_repeatedly(time_estimate)
	local checker
	local promise = Promise.empty()
	checker = function()
		local time = time_estimate()
		if time ~= nil then
			UIManager:scheduleIn(time, checker)
		else
			promise:resolve()
		end
	end
	checker()
	return promise, function()
		UIManager:unschedule(checker)
	end
end

function Promise.wait_while(condition)
	return Promise.wait_repeatedly(function()
		if condition() then
			return 0.2
		else
			return nil
		end
	end)
end

function Promise.instant()
	return Promise:new({ callbacks = nil })
end

function Promise.empty()
	return Promise:new({ callbacks = {} })
end

function Promise:wrap()
	local promise = Promise.empty()
	self:add_callback(function()
		promise:resolve()
	end)
	return promise
end

------------------ AUDIO MODULE -------------------
function TTS:request_server(body, endpoint)
	if endpoint == nil then
		endpoint = ""
	end
	body = rapidjson.encode(body)
	local result = {}
	local a, code = http.request({
		method = "POST",
		url = "http://" .. self.settings.hostname .. endpoint,
		source = ltn12.source.string(body),
		headers = {
			["Content-Length"] = #body,
			["Content-Type"] = "application/json",
		},
		sink = ltn12.sink.table(result),
	})
	if a == 1 then
		return code, result
	end
	return 500, {}
end

function TTS:server_get_voices()
	local result = {}
	local a, code = http.request({
		url = "http://" .. self.settings.hostname .. "/voices",
		source = ltn12.source.empty(),
		sink = ltn12.sink.table(result),
	})
	if a ~= 1 or code ~= 200 then
		return nil
	end
	return rapidjson.decode(table.concat(result))
end

function TTS:play(item)
	local body = util.tableDeepCopy(self.settings.server_extra_args or {}) or {}
	body.handle = item.handle
	local code, _ = self:request_server(body, "/play")
	if code ~= 200 then
		logger.err("TTS: could not play. Is the TTS server down?")
		return Promise:instant()
	end
	local promise, unschedule = Promise.wait_repeatedly(function()
		local code2, responce_table = self:request_server(body, "/remaining")
		if code2 ~= 200 then
			logger.err("TTS: could not get remaining time. Is the TTS server down?")
			return 0.1
		end
		local est = rapidjson.decode(table.concat(responce_table))
		if not est.started then
			return 0.2
		end
		if est.remaining == 0 then
			return nil
		end
		return math.max(0.01, est.remaining - 0.2)
	end)

	local promise2 = promise:wrap()
	promise2.on_cancel = function()
		unschedule()
		local code2, _ = self:request_server(body, "/stop")
		if code2 ~= 200 then
			logger.err("TTS: could not stop playback. Is the TTS server down?")
		end
	end
	return promise2
end

---@return Promise
function TTS:ensure_handle_on_item(item)
	if item.handle_promise ~= nil then
		return item.handle_promise
	end

	local download_thread = function(_, write_pipe)
		local body = util.tableDeepCopy(self.settings.server_extra_args or {}) or {}
		body.text = item.text
		if body.text == nil or body.text == "" then
			body.text = "a"
		end
		local code, handle_table = self:request_server(body)
		if code == 200 then
			local handle = table.concat(handle_table)
			ffiutil.writeToFD(write_pipe, handle, true)
		else
			ffiutil.writeToFD(write_pipe, "ERR", true)
		end
	end
	local pid, read_pipe = ffiutil.runInSubProcess(download_thread, true)
	local promise, unschedule = Promise.wait_while(function()
		return not ffiutil.isSubProcessDone(pid)
	end)
	promise:add_callback(function()
		local handle = ffiutil.readAllFromFD(read_pipe)
		if handle == "ERR" then
			logger.err("TTS: could not generate wav file from text. Is the TTS server down?")
			if item.handle_promise ~= nil then
				item.handle_promise:cancel()
			end
		end
		item.handle_promise = nil
		item.handle = handle
	end)
	item.handle_promise = promise:wrap()
	item.handle_promise.on_cancel = function()
		unschedule()
		ffiutil.terminateSubProcess(pid)
		item.handle_promise = nil
		item.handle = nil
	end
	return item.handle_promise
end

function TTS:stop_playing()
	if self.playing_promise ~= nil then
		self.playing_promise:cancel()
		self.playing_promise = nil
	end
end

function TTS:start_playing()
	local loop_once
	loop_once = function()
		local wav_for_the_next
		if self.next_item ~= nil then
			wav_for_the_next = self:ensure_handle_on_item(self.next_item)
		end
		self.playing_promise = self:play(self.current_item)
		self.playing_promise:add_callback(function()
			if wav_for_the_next == nil then
				-- We hit the end of the book in tts mode
				self:stop_playing()
				UIManager:close(self.widget)
				self:show_widget()
				return
			end
			self.prev_item = self.current_item
			self:change_highlight(self.next_item)
			self.next_item = self:item_next(self.next_item)
			self.playing_promise = wav_for_the_next
			wav_for_the_next:add_callback(loop_once)
		end)
	end
	self.playing_promise = self:ensure_handle_on_item(self.current_item)
	self.playing_promise:add_callback(function()
		loop_once()
	end)
end

return TTS
