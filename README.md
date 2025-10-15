# TermBuffer.nvim

A Neovim plugin that simulates a terminal experience within a standard buffer,
allowing command execution and history tracking with LSP integration.

## Features

- Buffer-based terminal simulation with command history
- LSP integration for shell script commands
- Visual distinction between commands and output
- Command execution via buffer saving (<C-s> or `:w`)
- Read-only history with editable command input area

## Installation

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  'saya-ashen/termbuffer.nvim',
  config = function()
    require('termbuffer').setup()
  end
}
```

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'saya-ashen/termbuffer.nvim',
  config = function()
    require('termbuffer').setup()
  end
}
```

## Requirements

- Neovim 0.5.0 or later
- (Optional) bash-language-server for LSP features
  - Install with: `npm install -g bash-language-server`

## Usage

1. Open a terminal buffer with the command `:TermBuffer`
2. Type your shell command at the prompt (`❯`)
3. Execute the command by:
   - Pressing `<C-s>` (Control+S)
   - Running the `:w` command
4. View the output below your command
5. Continue typing new commands at the prompt

## Configuration

You can customize the plugin with the setup function:

```lua
require('termbuffer').setup({
  prompt_symbol = "❯ ",           -- The prompt symbol
  command_highlight = "Statement", -- Highlight group for commands
  output_highlight = "Comment",    -- Highlight group for command output
  error_highlight = "ErrorMsg",    -- Highlight group for error output
  lsp = {
    enabled = true,               -- Enable LSP integration
    server = "bash-language-server", -- LSP server to use
    args = {"start"}              -- Arguments for the LSP server
  }
})
```

## How It Works

- The plugin creates a special buffer with a custom filetype (`termbuffer`)
- Commands are entered at the bottom of the buffer
- When executing a command:
  1. The command is processed asynchronously
  2. Output is appended to the buffer
  3. Previous commands and output become read-only
  4. A new prompt is added at the bottom
- LSP integration provides autocompletion and diagnostics for shell commands

## Tips

- Use the Enter key to create multi-line commands
- If you try to enter insert mode on a read-only section, your cursor will
  automatically move to the command input area
- The buffer shows a modified status (+) when a new command is being typed

## Health Check

Run `:checkhealth termbuffer` to verify your setup.

## License

MIT
