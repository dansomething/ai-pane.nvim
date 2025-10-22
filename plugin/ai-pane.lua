-- ai-pane.nvim - Neovim plugin for tmux integration with AI tools
-- This file is loaded automatically by Neovim when the plugin is installed

-- Prevent loading the plugin twice
if vim.g.loaded_ai_pane then
  return
end
vim.g.loaded_ai_pane = true

-- The plugin will be set up by the user calling require('ai-pane').setup()
-- in their init.lua/init.vim configuration file
