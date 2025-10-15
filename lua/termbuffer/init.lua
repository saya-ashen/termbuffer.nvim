local api = vim.api
local fn = vim.fn

local M = {}

-- Default configuration
M.config = {
	prompt_symbol = "❯ ",
	command_highlight = "TermCommand",
	output_highlight = "Comment",
	error_highlight = "ErrorMsg",
	lsp = {
		enabled = true,
		server = "bash-language-server",
		args = { "start" },
	},
}

-- Store buffer state information
M.buffer_state = {
	editable_line = 0,
	editing_allowed = true,
	buffers = {}, -- Track all termbuffer instances
}

-- Setup function to be called by user
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Create highlight groups
	vim.cmd([[
    highlight default link TermCommand Statement
  ]])

	-- Register buffer type commands
	api.nvim_create_user_command("TermBuffer", function()
		M.create_buffer()
	end, {})
end

-- Helper function to temporarily make buffer modifiable for edits
local function with_modifiable(buf, func)
	local was_modifiable = vim.bo[buf].modifiable
	vim.bo[buf].modifiable = true
	local success, result = pcall(func)
	vim.bo[buf].modifiable = was_modifiable
	if not success then
		error(result)
	end
	return result
end
-- 仅获取“当前命令”（最后一个 prompt 到缓冲区末尾）的文本；第一行去掉 prompt
local function get_current_command_text(buf)
	buf = buf or api.nvim_get_current_buf()

	local line_count = api.nvim_buf_line_count(buf)
	if line_count == 0 then
		return ""
	end

	local prompt = M.config.prompt_symbol
	local prompt_pat = "^" .. vim.pesc(prompt)

	-- 1) 从末尾向上找到“最后一个以 prompt 开头的行”
	local start_idx -- 0-based
	for i = line_count - 1, 0, -1 do
		local l = api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ""
		if l:match(prompt_pat) then
			start_idx = i
			break
		end
	end
	if not start_idx then
		-- 缓冲区里根本没有 prompt，视为没有命令
		return ""
	end

	-- 2) 取该行到末尾
	local lines = api.nvim_buf_get_lines(buf, start_idx, line_count, false)
	if #lines == 0 then
		return ""
	end

	-- 3) 第一行去掉 prompt；其余行原样
	lines[1] = (lines[1] or ""):gsub(prompt_pat, "", 1)

	-- 4) 去掉「命令块末尾的全空白行」（防止误多按回车导致空命令）
	while #lines > 0 and (lines[#lines] == "" or lines[#lines]:match("^%s*$")) do
		table.remove(lines, #lines)
	end

	return table.concat(lines, "\n")
end

-- Create a new terminal buffer
function M.create_buffer()
	local buf = api.nvim_create_buf(true, true)

	-- Buffer setup - IMPORTANT: Set buffer options before adding content
	api.nvim_buf_set_option(buf, "buftype", "acwrite") -- Custom write handling
	api.nvim_buf_set_option(buf, "filetype", "sh") -- Use sh filetype for LSP support
	api.nvim_buf_set_option(buf, "swapfile", false)
	api.nvim_buf_set_option(buf, "modifiable", true) -- Start as modifiable

	-- Initialize buffer state tracking
	M.buffer_state.buffers[buf] = {
		editable_line = 1, -- Start at line 1 (1-indexed)
		prompt_line = 0, -- Start at line 0 (0-indexed for API)
		prompt_length = #M.config.prompt_symbol,
		job_id = nil,
		stdin = nil,
		output_accum = {},
		error_accum = {},
		marker = nil,
		waiting = false,
	}

	-- Create the initial prompt - ensure buffer is empty first
	-- 用单行提示符替换整个缓冲区，避免留下最后一行的空行
	api.nvim_buf_set_lines(buf, 0, -1, false, { M.config.prompt_symbol })

	-- 显示上的高亮与状态记录（等价于你 create_prompt 做的事）
	local prompt_ns = api.nvim_create_namespace("termbuffer_prompt")
	api.nvim_buf_set_extmark(buf, prompt_ns, 0, 0, {
		end_col = #M.config.prompt_symbol,
		hl_group = "SpecialChar",
		priority = 101,
	})

	if not M.buffer_state.buffers[buf] then
		M.buffer_state.buffers[buf] = {}
	end
	M.buffer_state.buffers[buf].prompt_line = 0
	M.buffer_state.buffers[buf].prompt_length = #M.config.prompt_symbol
	M.buffer_state.buffers[buf].editable_line = 1

	-- Setup buffer state for editable line
	M.buffer_state.editable_line = 1 -- First line (1-indexed)

	-- Set up autocommands for handling edit restrictions
	local term_group = api.nvim_create_augroup("termbuffer_" .. buf, { clear = true })

	-- Control modifiable state based on cursor position
	api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
		group = term_group,
		buffer = buf,
		callback = function()
			local st = M.buffer_state.buffers[buf]
			if not st then
				return
			end

			vim.notify("TextChangedI triggered", vim.log.levels.DEBUG)
			local cursor = api.nvim_win_get_cursor(0)
			local line = cursor[1]

			-- Only allow editing on the last command block (from prompt_line to end)
			-- All history lines should be non-modifiable
			if line >= st.editable_line or line > st.prompt_line then
				vim.bo[buf].modifiable = true
				-- If editing the prompt area, move cursor after the prompt
				if line == st.prompt_line + 1 and cursor[2] < st.prompt_length then
					api.nvim_win_set_cursor(0, { line, st.prompt_length })
				end
			else
				vim.bo[buf].modifiable = false
			end
		end,
	})

	-- Intercept buffer changes to prevent edits on read-only lines
	-- api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
	-- 	group = term_group,
	-- 	buffer = buf,
	-- 	callback = function()
	-- 		if not M.buffer_state.editing_allowed then
	-- 			-- Temporarily disable the autocommand to avoid recursion
	-- 			M.buffer_state.editing_allowed = true
	-- 			-- Undo the change
	-- 			vim.cmd("undo")
	-- 			-- Notify user
	-- 			vim.notify("Cannot edit history. Only the current command line is editable.", vim.log.levels.WARN)
	-- 		end
	-- 	end,
	-- })

	-- Before buffer change check
	api.nvim_create_autocmd("BufModifiedSet", {
		group = term_group,
		buffer = buf,
		callback = function()
			local cursor = api.nvim_win_get_cursor(0)
			local line = cursor[1]
			vim.notify("TextChangedI triggered", vim.log.levels.DEBUG)

			-- Only allow edits on the last line
			if line < M.buffer_state.editable_line then
				M.buffer_state.editing_allowed = false
			else
				M.buffer_state.editing_allowed = true

				-- If editing the prompt area, move cursor after the prompt
				if line == M.buffer_state.editable_line and cursor[2] < M.buffer_state.buffers[buf].prompt_length then
					api.nvim_win_set_cursor(0, { line, M.buffer_state.buffers[buf].prompt_length })
				end
			end

			return true
		end,
	})

	-- Protect prompt from being deleted
	api.nvim_create_autocmd("InsertCharPre", {
		group = term_group,
		buffer = buf,
		callback = function()
			local cursor = api.nvim_win_get_cursor(0)
			local line = cursor[1] - 1 -- Convert to 0-based for extmark API
			local col = cursor[2]

			-- If trying to edit the prompt area, move cursor after prompt
			if line == M.buffer_state.buffers[buf].prompt_line and col < M.buffer_state.buffers[buf].prompt_length then
				api.nvim_win_set_cursor(0, { line + 1, M.buffer_state.buffers[buf].prompt_length })
			end
		end,
	})
	-- -- Prevent prompt deletion with backspace
	-- api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
	-- 	group = term_group,
	-- 	buffer = buf,
	-- 	callback = function(ev)
	-- 		local st = M.buffer_state.buffers[ev.buf]
	-- 		if not st then
	-- 			return
	-- 		end
	-- 		if st._restoring then
	-- 			return
	-- 		end -- 重入保护
	--
	-- 		local pl = st.prompt_line -- 0-based（若暂时没用 extmark）
	-- 		if not pl then
	-- 			return
	-- 		end
	--
	-- 		local line = api.nvim_buf_get_lines(ev.buf, pl, pl + 1, false)[1] or ""
	-- 		local prompt = M.config.prompt_symbol
	--
	-- 		-- 1) 规范化前缀：去掉“完整或部分提示符前缀”
	-- 		local function strip_partial_prefix(s, prefix)
	-- 			local max = math.min(#s, #prefix)
	-- 			local k = 0
	-- 			for i = 1, max do
	-- 				if s:sub(1, i) == prefix:sub(1, i) then
	-- 					k = i
	-- 				else
	-- 					break
	-- 				end
	-- 			end
	-- 			if k > 0 then
	-- 				return s:sub(k + 1)
	-- 			end
	-- 			return s
	-- 		end
	--
	-- 		local normalized_tail = strip_partial_prefix(line, prompt)
	-- 		local should_restore = (line ~= (prompt .. normalized_tail))
	--
	-- 		if should_restore then
	-- 			st._restoring = true
	-- 			pcall(function()
	-- 				api.nvim_buf_set_lines(ev.buf, pl, pl + 1, false, { prompt .. normalized_tail })
	-- 				local win = ev.win and api.nvim_win_is_valid(ev.win) and ev.win or nil
	-- 				if win then
	-- 					local cur = api.nvim_win_get_cursor(win)
	-- 					if cur[1] - 1 == pl and cur[2] < #prompt then
	-- 						api.nvim_win_set_cursor(win, { cur[1], #prompt })
	-- 					end
	-- 				end
	-- 			end)
	-- 			st._restoring = false
	-- 		end
	-- 	end,
	-- })

	-- Prevent prompt deletion with backspace and other edits
	api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		group = term_group,
		buffer = buf,
		callback = function(ev)
			local st = M.buffer_state.buffers[ev.buf]
			if not st then
				return
			end
			if st._restoring then
				return
			end -- 重入保护

			local pl = st.prompt_line -- 当前 prompt 行 (0-based)
			if not pl then
				return
			end

			local prompt = M.config.prompt_symbol
			st._restoring = true

			pcall(function()
				-- 1. 检查当前 prompt 行是否存在
				local line_count = api.nvim_buf_line_count(ev.buf)
				if pl >= line_count then
					-- prompt 行被删除了,需要恢复
					-- 在缓冲区末尾添加新的 prompt 行
					with_modifiable(ev.buf, function()
						api.nvim_buf_set_lines(ev.buf, line_count, line_count, false, { prompt })
					end)
					st.prompt_line = line_count
					st.editable_line = line_count + 1
					M.buffer_state.editable_line = line_count + 1

					-- 恢复光标位置
					local wins = vim.fn.win_findbuf(ev.buf)
					for _, win in ipairs(wins) do
						api.nvim_win_set_cursor(win, { line_count + 1, #prompt })
					end
					st._restoring = false
					return
				end

				-- 2. 检查 prompt 行的内容是否正确
				local line = api.nvim_buf_get_lines(ev.buf, pl, pl + 1, false)[1] or ""

				-- 规范化前缀:去掉"完整或部分提示符前缀"
				local function strip_partial_prefix(s, prefix)
					local max = math.min(#s, #prefix)
					local k = 0
					for i = 1, max do
						if s:sub(1, i) == prefix:sub(1, i) then
							k = i
						else
							break
						end
					end
					if k > 0 then
						return s:sub(k + 1)
					end
					return s
				end

				local normalized_tail = strip_partial_prefix(line, prompt)
				local expected_line = prompt .. normalized_tail

				if line ~= expected_line then
					-- prompt 被部分或完全删除,需要修复
					with_modifiable(ev.buf, function()
						api.nvim_buf_set_lines(ev.buf, pl, pl + 1, false, { expected_line })
					end)

					-- 调整光标位置(如果在被修复的行上)
					local wins = vim.fn.win_findbuf(ev.buf)
					for _, win in ipairs(wins) do
						local cur = api.nvim_win_get_cursor(win)
						if cur[1] - 1 == pl and cur[2] < #prompt then
							api.nvim_win_set_cursor(win, { cur[1], #prompt })
						end
					end
				end
			end)

			st._restoring = false
		end,
	})

	-- 另外,添加一个额外的保护层,防止在 normal 模式下删除 prompt 行
	api.nvim_create_autocmd("ModeChanged", {
		group = term_group,
		-- buffer = buf,
		pattern = "*:n", -- 进入 normal 模式时
		callback = function()
			local st = M.buffer_state.buffers[buf]
			if not st then
				return
			end

			-- 验证 prompt 行是否还存在
			vim.schedule(function()
				local line_count = api.nvim_buf_line_count(buf)
				local pl = st.prompt_line

				if pl >= line_count then
					-- prompt 行不见了,恢复它
					with_modifiable(buf, function()
						api.nvim_buf_set_lines(buf, line_count, line_count, false, { M.config.prompt_symbol })
					end)
					st.prompt_line = line_count
					st.editable_line = line_count + 1
					M.buffer_state.editable_line = line_count + 1
				end
			end)
		end,
	})

	-- Buffer-specific keymaps (including insert mode)
	-- Add Ctrl+S mapping for both normal and insert mode
	api.nvim_buf_set_keymap(
		buf,
		"n",
		"<C-s>",
		'<cmd>lua require("termbuffer").execute_command()<CR>',
		{ noremap = true, silent = true }
	)

	api.nvim_buf_set_keymap(
		buf,
		"i",
		"<C-s>",
		'<cmd>lua require("termbuffer").execute_command()<CR><cmd>startinsert<CR>',
		{ noremap = true, silent = true }
	)
	api.nvim_buf_set_keymap(
		buf,
		"n",
		"<leader>ts",
		'<cmd>lua require("termbuffer").interrupt_command()<CR>',
		{ noremap = true, silent = true }
	)
	api.nvim_buf_set_keymap(
		buf,
		"i",

		"<leader>ts",
		'<cmd>lua require("termbuffer").interrupt_command()<CR><cmd>startinsert<CR>',
		{ noremap = true, silent = true }
	)

	-- Display the buffer in the current window
	local win = api.nvim_get_current_win()
	api.nvim_win_set_buf(win, buf)

	-- Position cursor at the start of the editable area (after the prompt)
	api.nvim_win_set_cursor(win, { 1, M.buffer_state.buffers[buf].prompt_length })

	-- Mark the buffer as modified to show the "+" indicator
	vim.bo[buf].modified = true

	-- Enter insert mode
	vim.cmd("startinsert")

	return buf
end

-- Mark all content except last line as visually distinct
function M.highlight_history(buf)
	buf = buf or api.nvim_get_current_buf()
	local line_count = api.nvim_buf_line_count(buf)
	if line_count <= 1 then
		return
	end

	-- Store the editable line position for edit restriction checking
	M.buffer_state.editable_line = line_count
	if M.buffer_state.buffers[buf] then
		M.buffer_state.buffers[buf].editable_line = line_count
	end

	-- Create namespace for history highlighting
	local ns_id = api.nvim_create_namespace("termbuffer_history")

	-- Apply highlighting to command history
	for i = 0, line_count - 2 do
		local line_length = #api.nvim_buf_get_lines(buf, i, i + 1, false)[1]
		-- We're just using extmarks for highlighting, not for enforcing read-only
		api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
			end_line = i,
			end_col = line_length,
			priority = 100,
			right_gravity = false,
		})
	end
end

-- Execute the command at the last line

function M.execute_command()
	local buf = api.nvim_get_current_buf()
	local st = M.buffer_state.buffers[buf]
	if not st then
		vim.notify("Invalid termbuffer state", vim.log.levels.ERROR)
		return
	end

	local cmd = get_current_command_text(buf)

	-- 空命令处理（不变）
	if cmd == "" or cmd:match("^%s*$") then
		local line_count = api.nvim_buf_line_count(buf)
		with_modifiable(buf, function()
			api.nvim_buf_set_lines(buf, line_count, line_count, false, { M.config.prompt_symbol })
		end)
		M.buffer_state.editable_line = line_count + 1
		st.editable_line = line_count + 1
		st.prompt_line = line_count
		local win = api.nvim_get_current_win()
		api.nvim_win_set_cursor(win, { line_count + 1, #M.config.prompt_symbol })
		vim.cmd("startinsert")
		return
	end

	-- 启动/复用 bash job（不变）
	if not st.job_id then
		st.job_id = fn.jobstart("bash", {
			stdin = "pipe",
			on_stdout = function(_, data)
				M.on_stdout(buf, data)
			end,
			on_stderr = function(_, data)
				M.on_stderr(buf, data)
			end,
			on_exit = function()
				st.job_id = nil
				if st.waiting then
					-- 如果意外退出且仍在等待，清理状态
					st.waiting = false
					M.finish_command(buf)
				end
			end,
		})
		if st.job_id <= 0 then
			vim.notify("Failed to start bash", vim.log.levels.ERROR)
			return
		end
	end

	-- 生成 marker（不变）
	math.randomseed(os.time())
	local marker = "__TERM_BUFFER_END_" .. math.random(1000000, 9999999) .. "__"
	st.marker = marker
	st.waiting = true

	-- 发送命令（不变）
	fn.chansend(st.job_id, cmd .. "\necho " .. marker .. "\n")
end

-- 中断当前正在运行的命令
function M.interrupt_command()
	local buf = api.nvim_get_current_buf()
	local st = M.buffer_state.buffers[buf]
	if not st or not st.waiting or not st.job_id then
		-- 如果没有正在运行的命令，不做任何事
		return
	end

	-- 停止job
	fn.jobstop(st.job_id)
	st.waiting = false

	-- 清理并添加新提示符（类似finish_command，但不等待marker）
	M.finish_command(buf)
end

function M.on_stdout(buf, data)
	if not M.buffer_state.buffers[buf] or not M.buffer_state.buffers[buf].waiting then
		return
	end

	local st = M.buffer_state.buffers[buf]
	local line_count = api.nvim_buf_line_count(buf)

	for _, line in ipairs(data) do
		if line == st.marker then
			-- 检测到 marker，触发结束处理
			M.finish_command(buf)
			return
		end
		if line ~= "" then
			-- 立即追加输出行到缓冲区末尾
			with_modifiable(buf, function()
				api.nvim_buf_set_lines(buf, line_count, line_count, false, { line })
			end)
			-- 应用输出高亮
			local output_ns = api.nvim_create_namespace("termbuffer_output")
			api.nvim_buf_set_extmark(buf, output_ns, line_count, 0, {
				end_col = #line,
				hl_group = M.config.output_highlight,
				priority = 100,
			})
			line_count = line_count + 1
		end
	end

	-- 更新缓冲区状态（输出行变为只读）
	M.buffer_state.editable_line = line_count + 1
	st.editable_line = line_count + 1
end

function M.on_stderr(buf, data)
	if not M.buffer_state.buffers[buf] or not M.buffer_state.buffers[buf].waiting then
		return
	end

	local st = M.buffer_state.buffers[buf]
	local line_count = api.nvim_buf_line_count(buf)

	for _, line in ipairs(data) do
		if line ~= "" then
			-- 立即追加错误行到缓冲区末尾
			with_modifiable(buf, function()
				api.nvim_buf_set_lines(buf, line_count, line_count, false, { line })
			end)
			-- 应用错误高亮
			local error_ns = api.nvim_create_namespace("termbuffer_error")
			api.nvim_buf_set_extmark(buf, error_ns, line_count, 0, {
				end_col = #line,
				hl_group = M.config.error_highlight,
				priority = 100,
			})
			line_count = line_count + 1
		end
	end

	-- 更新缓冲区状态
	M.buffer_state.editable_line = line_count + 1
	st.editable_line = line_count + 1
end

function M.finish_command(buf)
	local st = M.buffer_state.buffers[buf]
	st.waiting = false
	local line_count = api.nvim_buf_line_count(buf)

	-- 添加新提示符
	with_modifiable(buf, function()
		api.nvim_buf_set_lines(buf, line_count, line_count, false, { M.config.prompt_symbol })
	end)

	-- 更新状态
	M.buffer_state.editable_line = line_count + 1
	st.editable_line = line_count + 1
	st.prompt_line = line_count

	-- 设置光标
	local win = api.nvim_get_current_win()
	api.nvim_win_set_cursor(win, { line_count + 1, #M.config.prompt_symbol })

	-- 标记为已修改
	vim.bo[buf].modified = true

	-- 进入插入模式
	vim.cmd("startinsert")
end
-- Attach LSP to the buffer
function M.attach_lsp(buf)
	buf = buf or api.nvim_get_current_buf()

	-- Try to start the LSP server
	local client_id = vim.lsp.start({
		name = M.config.lsp.server,
		cmd = { M.config.lsp.server, unpack(M.config.lsp.args) },
		root_dir = fn.getcwd(),
		capabilities = vim.lsp.protocol.make_client_capabilities(),
		settings = {
			bashIde = {
				globPattern = "*", -- Match all files in the terminal buffer
			},
		},
	})

	if not client_id then
		vim.notify("Failed to start " .. M.config.lsp.server, vim.log.levels.ERROR)
		return false
	end

	return true
end
return M
