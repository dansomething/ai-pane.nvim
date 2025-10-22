# ai-pane.nvim

A Neovim plugin for a lightweight integration with AI CLIs (Claude, Copilot, etc.) using tmux. Send files, buffers, and visual selections to your AI assistant without leaving your editor.

## Features

- **Smart Pane Management**: Automatically finds existing AI CLI panes or creates new ones
- **Multiple Send Modes**: Send file references, buffer contents, or visual selections
- **Predefined Prompts**: Built-in prompts for common tasks (Commit, Explain, Review, Tests, Fix, Optimize, Docs, Refactor)
- **Customizable**: Configure AI commands, keymaps, and add your own prompts
- **Tmux Integration**: Uses tmux to manage your AI CLI in a separate pane

## Requirements

- Neovim >= 0.7.0
- tmux
- An AI CLI tool installed and configured (e.g., [Claude CLI](https://github.com/anthropics/claude-cli), Copilot CLI, etc.)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'yourusername/ai-pane.nvim',
  config = function()
    require('ai-pane').setup()
  end
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'yourusername/ai-pane.nvim',
  config = function()
    require('ai-pane').setup()
  end
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'yourusername/ai-pane.nvim'

" In your init.vim or init.lua
lua << EOF
require('ai-pane').setup()
EOF
```

## Configuration

The plugin works out of the box with sensible defaults. Here's the default configuration:

```lua
require('ai-pane').setup({
  -- Command to start your AI CLI (default: "copilot")
  command = "copilot",

  -- Whether to create default keymaps (default: true)
  create_keymaps = true,

  -- Predefined prompts (can be extended or modified)
  prompts = {
    Commit = {
      prompt = "Write commit message for the change with commitizen convention...",
      mapping = "<leader>cpc",
    },
    Explain = {
      prompt = "Write an explanation for the selected code...",
      mapping = "<leader>cpe",
      normal_mode = "buffer",  -- Send buffer content in normal mode
    },
    Review = {
      prompt = "Review the following code...",
      mapping = "<leader>cpr",
    },
    Tests = {
      prompt = "Generate tests for the following code:",
      mapping = "<leader>cpt",
    },
    Fix = {
      prompt = "There is a problem in this code...",
      mapping = "<leader>cpf",
    },
    Optimize = {
      prompt = "Optimize the following code...",
      mapping = "<leader>cpo",
    },
    Docs = {
      prompt = "Add documentation comments for the following code:",
      mapping = "<leader>cpd",
    },
    Refactor = {
      prompt = "Refactor the following code...",
      mapping = "<leader>cpR",
    },
  },
})
```

### Custom Configuration Example

```lua
require('ai-pane').setup({
  -- Use a custom command if your AI CLI is not in PATH
  command = "/usr/local/bin/claude",

  -- Disable default keymaps if you want to define your own
  create_keymaps = false,

  -- Add custom prompts
  prompts = {
    -- Override existing prompts
    Explain = {
      prompt = "Explain this code in simple terms:",
      mapping = "<leader>ce",
      visual_mode = "selection",  -- Send actual code, not file reference
    },

    -- Add new prompts
    Translate = {
      prompt = "Translate this code to Python:",
      mapping = "<leader>cT",
    },
  },
})
```

## Usage

### Commands

| Command            | Description                                                    |
| ------------------ | -------------------------------------------------------------- |
| `:AIStart [h\|v]`  | Start AI CLI in a new tmux pane (h=horizontal, v=vertical)     |
| `:AIConnect`       | Connect to an existing AI CLI pane                             |
| `:AISendFile`      | Send current filename as `@filename` reference                 |
| `:AISendBuffer`    | Send entire buffer content                                     |
| `:AISendSelection` | Send visual selection (visual mode)                            |
| `:AISendRange`     | Send file path with line range `@file:start-end` (visual mode) |
| `:AIPrompt<Name>`  | Use a predefined prompt (e.g., `:AIPromptExplain`)             |

### Default Keymaps

#### Normal Mode

| Keymap        | Command             | Description                     |
| ------------- | ------------------- | ------------------------------- |
| `<leader>cn`  | `:AIStart v`        | Start AI CLI (vertical split)   |
| `<leader>cN`  | `:AIStart h`        | Start AI CLI (horizontal split) |
| `<leader>cc`  | `:AIConnect`        | Connect to existing pane        |
| `<leader>cs`  | `:AISendFile`       | Send filename reference         |
| `<leader>cb`  | `:AISendBuffer`     | Send buffer content             |
| `<leader>cpc` | `:AIPromptCommit`   | Generate commit message         |
| `<leader>cpe` | `:AIPromptExplain`  | Explain code                    |
| `<leader>cpr` | `:AIPromptReview`   | Review code                     |
| `<leader>cpt` | `:AIPromptTests`    | Generate tests                  |
| `<leader>cpf` | `:AIPromptFix`      | Fix code issues                 |
| `<leader>cpo` | `:AIPromptOptimize` | Optimize code                   |
| `<leader>cpd` | `:AIPromptDocs`     | Add documentation               |
| `<leader>cpR` | `:AIPromptRefactor` | Refactor code                   |

#### Visual Mode

| Keymap        | Command            | Description                             |
| ------------- | ------------------ | --------------------------------------- |
| `<leader>cs`  | `:AISendRange`     | Send file path with line range          |
| `<leader>cS`  | `:AISendSelection` | Send selected text                      |
| `<leader>cp*` | `:AIPrompt*`       | Prompt commands work in visual mode too |

### Workflow Examples

#### 1. Start AI CLI and Send a File

```
<leader>cn         " Start AI CLI in vertical split
<leader>cs         " Send current file reference (@filename)
```

#### 2. Explain Code

```
" Select code in visual mode, then:
<leader>cpe        " Explain the selected code
```

#### 3. Review and Fix Code

```
<leader>cpr        " Review current file
" Make changes based on feedback, then:
<leader>cpf        " Fix identified issues
```

#### 4. Generate Commit Message

```
" After staging changes:
<leader>cpc        " Generate commit message
```

## How It Works

1. **Pane Discovery**: The plugin scans tmux for running AI CLI instances
2. **Smart Connection**: If found, it connects to an existing pane; otherwise, it offers to create one
3. **Send Commands**: Uses `tmux send-keys` to send text to the AI CLI pane
4. **Context Modes**: Different modes control what gets sent:
   - `file`: Sends `@filename` (file reference)
   - `buffer`: Sends actual buffer content
   - `range`: Sends `@filename:start-end` (line range reference)
   - `selection`: Sends the actual selected text

## Known Issues

- **Authentication**: Depending on your AI CLI, authentication may need to be handled manually in the pane.
- **Vim Mode**: If your AI CLI has vim mode enabled, text won't be sent unless the CLI is in insert mode.

## Troubleshooting

### Commands not working

Ensure you have:

1. tmux installed and running
2. Your AI CLI tool installed and accessible in PATH
3. Neovim >= 0.7.0

### Custom keymaps not working

If you set `create_keymaps = false`, you need to define your own keymaps:

```lua
vim.keymap.set('n', '<leader>cs', ':AISendFile<CR>')
vim.keymap.set('v', '<leader>cs', ':AISendRange<CR>')
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

MIT
