-- neovim + tmux integration for AI CLI commands: connect to existing or create new AI CLI panes,
-- send filenames (@file syntax), buffer contents, or visual selections via tmux send-keys

-- Known Issues:
-- When vim mode is enabled in AI CLI, text won't be sent unless in insert mode

---@class AiPane
---@field setup fun(user_config?: {command?: string, create_keymaps?: boolean, current_window_only?: boolean, prompts?: table<string, {prompt: string, mapping?: string, normal_mode?: string, visual_mode?: string}>})
local M = {}

---@class Pane
---@field id string
---@field session string
---@field window string
---@field window_index string
---@field pane string
---@field pane_index string

---@type string|nil
local ai_pane = nil

-- Default Configuration
---@type {command: string, create_keymaps: boolean, current_window_only: boolean, prompts: table<string, {prompt: string, mapping?: string, normal_mode?: string, visual_mode?: string}>}
local default_config = {
  -- Default command for AI CLI
  command = "copilot",
  -- Whether to create default keymaps
  create_keymaps = true,
  -- Predefined prompts for convenience
  -- Whether to restrict AI pane search to the current tmux window only
  current_window_only = false,
  prompts = {
    Commit = {
      prompt = "Write commit message for the change with commitizen convention. Keep the title under 50 characters and wrap message at 72 characters. Format as a gitcommit code block.",
      mapping = "<leader>cpc",
      normal_mode = "none",
      visual_mode = "none",
    },
    Explain = {
      prompt = [[
Write an explanation for the selected code as paragraphs of text.

When explaining the code:
- Provide concise high-level overview first
- Highlight non-obvious implementation details
- Identify patterns and programming principles
- Address any existing diagnostics or warnings
- Focus on complex parts rather than basic syntax
- Use short paragraphs with clear structure
- Mention performance considerations where relevant
]],
      mapping = "<leader>cpe",
      -- visual_mode: "range" (default) sends @file:line-range, "selection" sends actual text
      -- normal_mode: "file" (default) sends @file, "buffer" sends actual buffer content
      normal_mode = "buffer",
    },

    Review = {
      prompt = [[
Review the following code and provide constructive feedback on potential issues, improvements, and best practices.

Check for:
- Unclear or non-conventional naming
- Comment quality (missing or unnecessary)
- Complex expressions needing simplification
- Deep nesting or complex control flow
- Inconsistent style or formatting
- Code duplication or redundancy
- Potential performance issues
- Error handling gaps
- Security concerns
- Breaking of SOLID principles

If no issues found, confirm the code is well-written and explain why.
]],
      mapping = "<leader>cpr",
    },

    Tests = {
      prompt = "Generate tests for the following code:",
      mapping = "<leader>cpt",
    },

    Fix = {
      prompt = "There is a problem in this code. Identify the issues and rewrite the code with fixes. Explain what was wrong and how your changes address the problems:",
      mapping = "<leader>cpf",
    },

    Optimize = {
      prompt = "Optimize the following code to improve performance and readability. Explain your optimization strategy and the benefits of your changes:",
      mapping = "<leader>cpo",
    },

    Docs = {
      prompt = "Add documentation comments for the following code:",
      mapping = "<leader>cpd",
    },

    Refactor = {
      prompt = "Refactor the following code to improve readability, maintainability, and performance without changing functionality:",
      mapping = "<leader>cpR",
    },

    UseEditor = {
      prompt = "For editor integration, find the neovim socket by listing files matching `/tmp/nvim*`. If multiple sockets exist, ask which one to use.",
      mapping = "<leader>cpn",
      normal_mode = "none",
      visual_mode = "none",
    },
  },
}

-- Default and user configuration merged
---@type {command: string, create_keymaps: boolean, current_window_only: boolean, prompts: table<string, {prompt: string, mapping?: string, normal_mode?: string, visual_mode?: string}>}
local config = {}

-- Execute shell command and return trimmed output
-- Used for tmux commands that need to capture output like pane IDs
---@param cmd string
---@return string|nil
local function sh(cmd)
  local h = io.popen(cmd)
  if not h then
    return nil
  end
  local out = h:read("*a") or ""
  local success = h:close()
  if not success then
    return nil
  end -- Command failed
  return vim.trim(out)
end

---@param str string
---@return string
local function firstToUpperFull(str)
  -- Lowercase the whole string first, then capitalize the first character
  local lowerStr = str:lower()
  return (lowerStr:gsub("^%l", string.upper))
end

-- Get the basename of a path (e.g., "/usr/bin/claude" -> "claude")
---@param path string
---@return string
local function basename(path)
  return path:match("([^/]+)$") or path
end

-- Check if pane content contains AI CLI command indicators
-- Returns true if the content appears to be from an AI CLI command.
---@param content string|nil
---@return boolean
local function is_ai_pane_content(content)
  if not content or content == "" then
    return false
  end

  -- Check for command name in content (use basename in case command is a path)
  local cmd_name = basename(config.command)
  if string.lower(content):match(string.lower(cmd_name)) then
    return true
  end

  -- Vim mode indicators - check with context to avoid false positives
  if content:match("INSERT") and string.find(content, "───", 1, true) then
    return true
  end
  if content:match("NORMAL") and string.find(content, "───", 1, true) then
    return true
  end

  return false
end

-- Search all tmux panes for ones running the configured AI CLI command.
-- When config.current_window_only is true, only searches the current window.
-- Returns a table of panes with contextual information
-- Each entry: {id = "%123", session = "main", window = "editor", window_index = 1, pane = "Claude", pane_index = 2 }
---@return table<integer, Pane>
local function find_ai_panes()
  local all_flag = config.current_window_only and "" or "-a "
  local panes_output = sh(
    "tmux list-panes "
      .. all_flag
      .. "-F '#{pane_id}|#{session_name}|#{window_name}|#{window_index}|#{pane_index}|#{pane_current_command}|#{pane_title}'"
  )
  if not panes_output then
    return {}
  end

  local panes = {}
  local cmd_name = basename(config.command)
  for line in panes_output:gmatch("[^\n]+") do
    local pane_id, session, window, win_idx, pane_idx, command, title =
      line:match("^(%%[0-9]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    local is_ai = false

    -- Check 1: Command name matches configured AI command (use basename in case command is a path)
    if command and string.lower(command):match(string.lower(cmd_name)) then
      is_ai = true
    end

    -- Check 2: Pane title has AI command name
    if title and string.lower(title):match(string.lower(cmd_name)) then
      is_ai = true
    end

    -- Check 3: For node/bash processes (wrapper scripts), check pane content
    -- This catches idle AI CLI command sessions that don't have distinctive titles
    if not is_ai and (command == "node" or command == "bash") then
      local content = sh(string.format("tmux capture-pane -t %s -p", pane_id))
      if is_ai_pane_content(content) then
        is_ai = true
      end
    end

    if pane_id and is_ai then
      table.insert(panes, {
        id = pane_id,
        session = session,
        window = window,
        window_index = win_idx,
        pane = title,
        pane_index = pane_idx,
      })
    end
  end
  return panes
end

-- Check if we have a valid AI CLI pane ID stored
---@return boolean
local function ensure_pane()
  if not ai_pane or #ai_pane == 0 then
    return false
  end

  -- Verify the stored pane still exists by checking tmux directly
  local pane_exists =
    sh(string.format("tmux list-panes -a -F '#{pane_id}' | grep -q '^%s$' && echo 1 || echo 0", ai_pane))
  if pane_exists == "1" then
    return true
  else
    -- Our stored pane no longer exists, clear it
    ai_pane = nil
    return false
  end
end

-- Wait for AI CLI command to be ready by polling pane output
-- Checks for AI CLI command prompt indicator to confirm it's ready to receive input
---@param pane_id string
---@param callback fun(success: boolean)|nil
---@param timeout_ms integer|nil
local function wait_for_ai_pane_ready(pane_id, callback, timeout_ms)
  timeout_ms = timeout_ms or 5000 -- 5 second timeout
  local start_time = vim.loop.now()
  local check_interval = 200 -- Check every 200ms (less aggressive)
  local check_count = 0

  local function check()
    vim.schedule(function()
      check_count = check_count + 1
      local elapsed = vim.loop.now() - start_time

      if elapsed > timeout_ms then
        vim.notify("Timeout waiting for AI CLI command to start, but continuing...", vim.log.levels.WARN)
        if callback then
          callback(true)
        end
        return
      end

      -- Capture entire visible pane content to check for AI CLI command prompt
      -- Use vim.fn.system instead of sh() to avoid blocking
      local output = vim.fn.system(string.format("tmux capture-pane -t %s -p", pane_id))

      -- Check if pane shows AI CLI command indicators
      if is_ai_pane_content(output) then
        if callback then
          callback(true)
        end
      else
        vim.defer_fn(check, check_interval)
      end
    end)
  end

  -- Start checking after brief initial delay to let tmux settle
  vim.defer_fn(check, 300)
end

-- Create a new tmux pane and start AI CLI command in it
-- split_flag: "h" for horizontal (top/bottom), anything else for vertical (left/right)
---@param split_flag string
local function start_ai_pane(split_flag)
  local flag = (split_flag == "h") and "-v" or "-h" -- tmux flags are inverted from intuition

  local run = config.command

  local pane = sh(("tmux split-window %s -P -F '#{pane_id}' %s"):format(flag, vim.fn.shellescape(run)))
  if pane and #pane > 0 then
    ai_pane = pane
    local title = firstToUpperFull(basename(run))
    os.execute(string.format("tmux select-pane -t %s -T %s", pane, title))
    vim.notify("Created new AI pane: " .. pane .. " (" .. flag .. ")")
  else
    vim.notify(string.format("Failed to start AI CLI command (%s)", config.command), vim.log.levels.ERROR)
  end
end

-- Format a pane's contextual information for display
---@param pane Pane
---@return string
local function format_pane_desc(pane)
  return string.format(
    "[session %s, window %s:%s, pane %s:%s]",
    pane.session,
    pane.window_index,
    pane.window,
    pane.pane_index,
    pane.pane
  )
end

-- Create a new AI pane and wait for it to be ready
---@param callback fun(success: boolean)|nil
local function create_new_pane(callback)
  start_ai_pane("v") -- Default to vertical split
  if ai_pane ~= nil then
    wait_for_ai_pane_ready(ai_pane, callback)
  end
end

-- Connect to an existing pane without prompting
---@param pane Pane
---@param callback fun(success: boolean)|nil
local function connect_to_pane(pane, callback)
  ai_pane = pane.id
  vim.notify("Connected to AI pane: " .. format_pane_desc(pane))
  if callback then
    callback(true)
  end
end

-- Handle the case when a single AI pane exists
---@param pane Pane
---@param callback fun(success: boolean)|nil
local function handle_single_pane(pane, callback)
  local pane_desc = format_pane_desc(pane)
  vim.ui.select({ "Yes", "No" }, {
    prompt = "Found existing AI pane: " .. pane_desc .. ". Connect to it?",
  }, function(choice)
    vim.schedule(function()
      vim.cmd("redraw")
      if choice == "Yes" then
        connect_to_pane(pane, callback)
      elseif choice == "No" then
        create_new_pane(callback)
      else
        -- User cancelled (pressed ESC)
        if callback then
          callback(false)
        end
      end
    end)
  end)
end

-- Handle the case when multiple AI panes exist
---@param panes table<integer, Pane>
---@param callback fun(success: boolean)|nil
local function handle_multiple_panes(panes, callback)
  local choices = {}
  for _, pane in ipairs(panes) do
    table.insert(choices, format_pane_desc(pane))
  end
  table.insert(choices, "Create new AI pane")

  vim.ui.select(choices, {
    prompt = string.format("Found %d AI panes. Select one:", #panes),
  }, function(choice, idx)
    vim.schedule(function()
      vim.cmd("redraw")
      if not choice then
        -- User cancelled
        if callback then
          callback(false)
        end
        return
      end

      if idx <= #panes then
        connect_to_pane(panes[idx], callback)
      else
        create_new_pane(callback)
      end
    end)
  end)
end

-- Main connection logic: find existing panes or create a new one
---@param callback fun(success: boolean)|nil
local function connect_ai_pane(callback)
  local existing_panes = find_ai_panes()

  if #existing_panes == 0 then
    create_new_pane(callback)
  elseif #existing_panes == 1 then
    handle_single_pane(existing_panes[1], callback)
  else
    handle_multiple_panes(existing_panes, callback)
  end
end

-- Send text to the AI pane via tmux send-keys
-- Uses -- separator to prevent text starting with -- from being interpreted as tmux flags
---@param text string
---@param press_enter boolean|nil
local function send_text(text, press_enter)
  local function do_send()
    local escaped_text = vim.fn.shellescape(text)
    local cmd = string.format("tmux send-keys -t %s -- %s", ai_pane, escaped_text)

    if press_enter then
      cmd = cmd .. string.format(" && tmux send-keys -t %s Enter", ai_pane)
    end

    local result = os.execute(cmd)
    if result ~= 0 then
      vim.notify("Failed to send text to AI pane", vim.log.levels.ERROR)
    end
  end

  if not ensure_pane() then
    connect_ai_pane(function(success)
      if success then
        do_send()
      end
    end)
  else
    do_send()
  end
end

-- Get current filename or nil with error notification
---@return string|nil
local function get_filename()
  local filename = vim.fn.expand("%")
  if filename == "" then
    vim.notify("No file name for this buffer.", vim.log.levels.WARN)
    return nil
  end
  return filename
end

---@return nil
local function send_filename()
  local filename = get_filename()
  if not filename then
    return
  end
  -- Use @ prefix for file references (supported by Claude and similar AI tools)
  send_text("@" .. filename, false)
end

-- Get the current visual selection text
-- Returns the selected text or nil if no selection found
---@return string|nil
local function get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getline(start_pos[2], end_pos[2])

  -- vim.fn.getline can return string or table depending on line count
  if type(lines) == "string" then
    lines = { lines }
  end

  if #lines == 0 then
    return nil
  end

  -- Trim lines to the actual selected portion
  if #lines == 1 then
    -- Single line selection: extract just the selected characters
    lines[1] = string.sub(lines[1], start_pos[3], end_pos[3])
  else
    -- Multi-line selection: trim first and last lines
    lines[1] = string.sub(lines[1], start_pos[3]) -- From start column to end
    lines[#lines] = string.sub(lines[#lines], 1, end_pos[3]) -- From beginning to end column
  end

  return table.concat(lines, "\n")
end

-- Send the current visual selection to AI
-- Handles both full line and partial line selections correctly
---@return nil
local function send_visual_selection()
  local selection_text = get_visual_selection()
  if not selection_text then
    vim.notify("No visual selection found.", vim.log.levels.WARN)
    return
  end
  send_text(selection_text, false)
end

-- Get file path with line range based on visual selection
-- Returns reference like @home/.config/nvim/lua/claude.lua:213-215
---@return string|nil
local function get_visual_range()
  local filename = get_filename()
  if not filename then
    return nil
  end

  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]

  if start_line == end_line then
    return string.format("@%s:%d", filename, start_line)
  else
    return string.format("@%s:%d-%d", filename, start_line, end_line)
  end
end

-- Send file path with line range based on visual selection to AI
-- Example output: @home/.config/nvim/lua/claude.lua:213-215
---@return nil
local function send_visual_range()
  local range_ref = get_visual_range()
  if not range_ref then
    return
  end
  send_text(range_ref, false)
end

-- Send buffer content in manageable chunks
-- Chunking prevents shell command length limit errors that occur with very long lines
-- or large files (e.g., minified code, generated files)
---@return nil
local function send_buffer_chunks()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)

  -- Character-based chunking is more reliable than line-based for files with very long lines
  local max_chunk_chars = 10000 -- 10KB chunks avoid tmux command length limits
  local chunk_lines = {}
  local chunk_chars = 0

  for _, line in ipairs(lines) do
    local line_chars = #line + 1 -- +1 accounts for newline character

    -- Send current chunk if adding this line would exceed the limit
    if chunk_chars + line_chars > max_chunk_chars and #chunk_lines > 0 then
      send_text(table.concat(chunk_lines, "\n"), false)
      chunk_lines = {}
      chunk_chars = 0
    end

    table.insert(chunk_lines, line)
    chunk_chars = chunk_chars + line_chars
  end

  -- Send any remaining lines in the final chunk
  if #chunk_lines > 0 then
    send_text(table.concat(chunk_lines, "\n"), false)
  end
end

-- Send entire buffer to AI in manageable chunks
---@return nil
local function send_buffer()
  send_buffer_chunks()
end

-- Send a prompt with optional context
-- context_mode: "range" (visual range), "selection" (visual selection text),
--               "file" (@filename), "buffer" (buffer contents), or "none" (no context)
---@param prompt_text string
---@param context_mode string
---@return nil
local function send_prompt(prompt_text, context_mode)
  -- Special handling for buffer mode to use chunking with proper async flow
  if context_mode == "buffer" then
    -- Ensure pane exists first, then send all content
    if not ensure_pane() then
      connect_ai_pane(function(success)
        if success then
          -- Now pane is ready, send everything
          vim.schedule(function()
            send_text(prompt_text .. "\n\n", false)
            send_buffer_chunks()
            send_text("", true) -- Just press enter
          end)
        end
      end)
    else
      -- Pane already exists, send immediately
      send_text(prompt_text .. "\n\n", false)
      send_buffer_chunks()
      send_text("", true)
    end
    return
  end

  -- For other modes, build the full text
  local context = ""

  if context_mode == "none" then
    -- No context, just send the prompt
  elseif context_mode == "range" then
    context = get_visual_range() or ""
  elseif context_mode == "selection" then
    context = get_visual_selection() or ""
  elseif context_mode == "file" then
    local filename = get_filename()
    if filename then
      context = "@" .. filename
    end
  end

  local full_text = prompt_text
  if context ~= "" then
    full_text = prompt_text .. "\n\n" .. context
  end

  send_text(full_text, true)
end

vim.api.nvim_create_user_command("AIStart", function(opts)
  start_ai_pane(opts.args == "h" and "h" or "v")
end, { nargs = "?" })

vim.api.nvim_create_user_command("AIConnect", function()
  connect_ai_pane(nil)
end, {})

vim.api.nvim_create_user_command("AISendFile", function()
  send_filename()
end, {})

vim.api.nvim_create_user_command("AISendBuffer", function()
  send_buffer()
end, {})

vim.api.nvim_create_user_command("AISendSelection", function()
  send_visual_selection()
end, { range = true })

vim.api.nvim_create_user_command("AISendRange", function()
  send_visual_range()
end, { range = true })

vim.api.nvim_create_user_command("AIListPanes", function()
  local panes = find_ai_panes()
  if #panes == 0 then
    vim.notify("No AI panes found.", vim.log.levels.INFO)
    return
  end

  local pane_descriptions = {}
  for _, pane in ipairs(panes) do
    table.insert(pane_descriptions, format_pane_desc(pane))
  end

  vim.notify("Found AI panes:\n" .. table.concat(pane_descriptions, "\n"), vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("AIStartNvimServer", function(opts)
  local socket_path = opts.args ~= "" and opts.args or "/tmp/nvim-ai-cli.sock"
  local ok, err = pcall(vim.fn.serverstart, socket_path)
  if ok then
    vim.notify("neovim server started at: " .. socket_path)
  else
    vim.notify("Failed to start neovim server: " .. tostring(err), vim.log.levels.ERROR)
  end
end, { nargs = "?", desc = "Start neovim server for AI CLI integration" })

-- Allow users to override config
---@param user_config? {command?: string, create_keymaps?: boolean, prompts?: table<string, {prompt: string, mapping?: string, normal_mode?: string, visual_mode?: string}>}
function M.setup(user_config)
  config = vim.tbl_deep_extend("force", default_config, user_config or {})
  if not config.command then
    vim.notify("Configure a CLI command (copilot, claude, etc.) in the setup configuration.", vim.log.levels.ERROR)
    return
  end

  -- Create prompt commands and keymaps
  for name, prompt_config in pairs(config.prompts) do
    local prompt_text = prompt_config.prompt or prompt_config
    if type(prompt_text) == "string" then
      -- Get context modes with defaults
      local visual_mode = prompt_config.visual_mode or "range" -- default: @file:line-range
      local normal_mode = prompt_config.normal_mode or "file" -- default: @file

      -- Create user command that works in both normal and visual mode
      vim.api.nvim_create_user_command("AIPrompt" .. name, function(opts)
        local mode = vim.fn.mode()
        if opts.range > 0 or mode == "v" or mode == "V" or mode == "\22" then
          send_prompt(prompt_text, visual_mode)
        else
          send_prompt(prompt_text, normal_mode)
        end
      end, { range = true })

      -- Create keymaps if mapping is specified
      if config.create_keymaps and prompt_config.mapping then
        vim.keymap.set("n", prompt_config.mapping, ":AIPrompt" .. name .. "<CR>")
        vim.keymap.set("v", prompt_config.mapping, ":AIPrompt" .. name .. "<CR>")
      end
    end
  end

  -- Create keymaps if enabled
  if config.create_keymaps then
    vim.keymap.set("n", "<leader>cn", ":AIStart v<CR>", { desc = "Start AI CLI (left/right split)" })
    vim.keymap.set("n", "<leader>cN", ":AIStart h<CR>", { desc = "Start AI CLI (top/bottom split)" })
    vim.keymap.set("n", "<leader>cc", ":AIConnect<CR>", { desc = "Connect to existing AI CLI pane" })
    vim.keymap.set("n", "<leader>cs", ":AISendFile<CR>", { desc = "Send current filename to AI CLI pane" })
    vim.keymap.set("n", "<leader>cb", ":AISendBuffer<CR>", { desc = "Send entire buffer to AI CLI" })
    vim.keymap.set("v", "<leader>cS", ":AISendSelection<CR>", { desc = "Send visual selection to AI CLI" })
    vim.keymap.set("v", "<leader>cs", ":AISendRange<CR>", { desc = "Send file path with line range to AI CLI" })
  end
end

return M
