local MiniPick = require("mini.pick")

local M = {}
local notify = require("atlas.core.notify")
local namespace = vim.api.nvim_create_namespace("atlas.picker.mini_pick")

local function cancel(handle)
	if handle then
		handle.cancel()
	end
end

---@param request AtlasPickerRequest
---@param item any
---@return table
local function entry(request, item)
	local text, chunks = require("atlas.ui.picker").format_item(request, item)
	return {
		text = text:gsub("[\r\n]", " "),
		item = item,
		chunks = chunks,
	}
end

---@param entries table[]
---@param buf integer
local function show(entries, buf)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	local marked = {}
	local matches = MiniPick.get_picker_matches()
	if matches then
		for _, item in ipairs(matches.marked or {}) do
			marked[item] = true
		end
	end
	local lines = {}
	for index, value in ipairs(entries) do
		local marker = marked[value] and "✓ " or "  "
		lines[index] = marker .. value.text
		local col = #marker
		for _, chunk in ipairs(value.chunks) do
			if chunk[2] then
				vim.api.nvim_buf_set_extmark(buf, namespace, index - 1, col, {
					end_col = col + #chunk[1],
					hl_group = chunk[2],
					priority = 200,
				})
			end
			col = col + #chunk[1]
		end
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

---@param request AtlasPickerRequest
function M.open(request)
	local active = true
	local confirmed = false
	local timer
	local fetch_handle
	local preview_handle
	local preview_generation = 0
	local pending_query
	local loaded_query = request.fetch and (request.fetch_on_open == false and "" or nil) or ""
	local entries = vim.tbl_map(function(item)
		return entry(request, item)
	end, request.items)
	local selected = {}
	for _, item in ipairs(request.selected) do
		selected[request.key(item)] = true
	end

	local function fetch(query, querytick)
		pending_query = query
		local function run()
			timer = nil
			if not active then
				return
			end
			fetch_handle = request.fetch(query, function(items, err)
				vim.schedule(function()
					if not active or not MiniPick.is_picker_active() or MiniPick.get_querytick() ~= querytick then
						return
					end
					fetch_handle = nil
					pending_query = nil
					loaded_query = query
					if err then
						notify.error(err, { vim_notify = true })
					end
					entries = vim.tbl_map(function(item)
						return entry(request, item)
					end, items or {})
					MiniPick.set_picker_items(entries, { querytick = querytick })
				end)
			end)
		end
		if (request.debounce_ms or 0) > 0 then
			timer = vim.defer_fn(run, request.debounce_ms)
		else
			run()
		end
	end

	local function match(stritems, inds, query)
		local query_text = table.concat(query)
		if request.fetch and query_text ~= loaded_query and query_text ~= pending_query then
			cancel(fetch_handle)
			cancel(preview_handle)
			if timer then
				timer:stop()
				timer:close()
				timer = nil
			end
			fetch(query_text, MiniPick.get_querytick())
		end
		return MiniPick.default_match(stritems, inds, query, { sync = true })
	end

	local function choose(item)
		confirmed = true
		vim.schedule(function()
			request.on_done(item.item)
		end)
	end

	local function choose_marked(items)
		confirmed = true
		vim.schedule(function()
			request.on_done(vim.tbl_map(function(value)
				return value.item
			end, items))
		end)
	end

	vim.api.nvim_create_autocmd("User", {
		pattern = "MiniPickStop",
		once = true,
		callback = function()
			active = false
			cancel(fetch_handle)
			cancel(preview_handle)
			if timer then
				timer:stop()
				timer:close()
			end
			if not confirmed and request.on_cancel then
				request.on_cancel()
			end
		end,
	})

	MiniPick.start({
		source = {
			name = request.title,
			items = entries,
			match = match,
			show = function(buf, items)
				show(items, buf)
			end,
			preview = request.preview_item and function(buf, item)
				cancel(preview_handle)
				preview_generation = preview_generation + 1
				local generation = preview_generation
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading..." })
				preview_handle = request.preview_item(item.item, function(preview)
					vim.schedule(function()
						if active and generation == preview_generation and vim.api.nvim_buf_is_valid(buf) then
							vim.api.nvim_buf_set_lines(buf, 0, -1, false, preview.lines)
							vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
						end
					end)
				end)
			end or nil,
			choose = not request.multi and choose or nil,
			choose_marked = request.multi and choose_marked or nil,
		},
		mappings = request.multi and {
			mark = "<Tab>",
			choose = "<C-s>",
			choose_marked = "<CR>",
		} or nil,
		window = {
			config = {
				width = math.floor(vim.o.columns * request.size.width),
				height = math.floor(vim.o.lines * request.size.height),
			},
		},
	})

	if request.multi then
		local marked = {}
		for index, value in ipairs(entries) do
			if selected[request.key(value.item)] then
				marked[#marked + 1] = index
			end
		end
		if #marked > 0 then
			MiniPick.set_picker_match_inds(marked, "marked")
		end
	end
	if request.initial_index then
		local matches = MiniPick.get_picker_matches()
		if matches and matches.all_inds[request.initial_index] then
			MiniPick.set_picker_match_inds({ matches.all_inds[request.initial_index] }, "current")
		end
	end
end

return M
