local M = {}

function M.check()
	local health = vim.health or require("health")
	local start = health.start or health.report_start
	local ok = health.ok or health.report_ok
	local warn = health.warn or health.report_warn
	local error = health.error or health.report_error

	start("TermBuffer Health Check")

	-- Check for jobstart support
	if vim.fn.has("nvim-0.5.0") == 1 then
		ok("Neovim version supports jobstart")
	else
		error("Neovim 0.5.0+ required")
	end

	-- Check for LSP support
	if vim.fn.has("nvim-0.5.0") == 1 then
		ok("LSP support available")
	else
		warn("LSP support requires Neovim 0.5.0+")
	end

	-- Check if bash-language-server is installed
	local bash_server = vim.fn.executable("bash-language-server")
	if bash_server == 1 then
		ok("bash-language-server found")
	else
		warn(
			"bash-language-server not found. LSP features won't be available. Install with npm: npm i -g bash-language-server"
		)
	end
end

return M
