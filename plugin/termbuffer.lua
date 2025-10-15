-- Avoid loading twice
if vim.g.loaded_termbuffer then
  return
end
vim.g.loaded_termbuffer = true

-- Create autocommand group
local termbuffer_group = vim.api.nvim_create_augroup('termbuffer_cmds', { clear = true })

-- Setup for termbuffer filetype
vim.api.nvim_create_autocmd("FileType", {
  group = termbuffer_group,
  pattern = "sh",
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    
    -- Only apply to termbuffer buffers (those with buftype acwrite)
    if vim.bo[buf].buftype ~= "acwrite" then
      return
    end

    -- Handle insert mode attempts on read-only sections
    vim.api.nvim_create_autocmd({ "InsertEnter" }, {
      buffer = buf,
      callback = function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local line_count = vim.api.nvim_buf_line_count(buf)
        local bufstate = require('termbuffer').buffer_state.buffers[buf]

        -- If not on the last line, move to the last line
        if bufstate and cursor[1] ~= line_count then
          vim.api.nvim_win_set_cursor(0, { line_count, bufstate.prompt_length })
        end
      end
    })

    -- Handle save events to execute commands
    vim.api.nvim_create_autocmd({ "BufWriteCmd" }, {
      buffer = buf,
      callback = function()
        require('termbuffer').execute_command()
        return true -- Prevent actual file writing
      end
    })

    -- Mark buffer as modified initially to show the "+" indicator
    vim.bo[buf].modified = true

    -- Attach LSP if enabled
    if require('termbuffer').config.lsp.enabled then
      require('termbuffer').attach_lsp(buf)
    end
  end
})
