local M = {}

M.config = {
  sessions_dir = vim.fn.stdpath("data") .. "/workmark_sessions",
  auto_save = true,
  max_sessions = 20,
}

local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, "p")
  end
end

local function sanitize(name)
  return name:gsub("[^%w%-_]", "_")
end

local function session_path(name)
  return M.config.sessions_dir .. "/" .. sanitize(name) .. ".vim"
end

local function project_key()
  local cwd = vim.fn.getcwd()
  return sanitize(cwd)
end

local function list_sessions()
  ensure_dir(M.config.sessions_dir)
  local sessions = {}
  local files = vim.fn.glob(M.config.sessions_dir .. "/*.vim", false, true)
  for _, filepath in ipairs(files) do
    local name = vim.fn.fnamemodify(filepath, ":t:r")
    local mtime = vim.fn.getftime(filepath)
    table.insert(sessions, { name = name, path = filepath, mtime = mtime })
  end
 
  table.sort(sessions, function(a, b) return a.mtime > b.mtime end)
  return sessions
end

function M.save(name)
  ensure_dir(M.config.sessions_dir)
  name = name or project_key()
  local path = session_path(name)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local bt = vim.api.nvim_buf_get_option(buf, "buftype")
    if bt ~= "" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local ok, err = pcall(function()
    vim.cmd("mksession! " .. vim.fn.fnameescape(path))
  end)

  if ok then
    vim.notify("[workmark] Session saved: " .. name, vim.log.levels.INFO)
    M._enforce_max(name)
  else
    vim.notify("[workmark] Failed to save session: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M._enforce_max(skip_name)
  local sessions = list_sessions()
  if #sessions <= M.config.max_sessions then return end
  for i = M.config.max_sessions + 1, #sessions do
    if sessions[i].name ~= sanitize(skip_name or "") then
      vim.fn.delete(sessions[i].path)
    end
  end
end

function M.load(name)
  name = name or project_key()
  local path = session_path(name)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[workmark] Session not found: " .. name, vim.log.levels.WARN)
    return
  end

  local ok, err = pcall(function()
    vim.cmd("source " .. vim.fn.fnameescape(path))
  end)

  if ok then
    vim.notify("[workmark] Session loaded: " .. name, vim.log.levels.INFO)
  else
    vim.notify("[workmark] Failed to load session: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.delete(name)
  if not name or name == "" then
    vim.notify("[workmark] No session name provided.", vim.log.levels.WARN)
    return
  end
  local path = session_path(name)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[workmark] Session not found: " .. name, vim.log.levels.WARN)
    return
  end
  vim.fn.delete(path)
  vim.notify("[workmark] Session deleted: " .. name, vim.log.levels.INFO)
end

local ui_state = {
  buf = nil,
  win = nil,
  sessions = {},
}

local HELP_LINES = {
  "  [Enter] Load   [d] Delete   [s] Save new   [r] Rename   [q/Esc] Close",
}

local HEADER = {
  "  ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███╗   ███╗ █████╗ ██████╗ ██╗  ██╗",
  "  ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝████╗ ████║██╔══██╗██╔══██╗██║ ██╔╝",
  "  ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ██╔████╔██║███████║██████╔╝█████╔╝ ",
  "  ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ██║╚██╔╝██║██╔══██║██╔══██╗██╔═██╗ ",
  "  ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██╗",
  "   ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝",
  "",
}

local function format_time(mtime)
  local diff = os.time() - mtime
  if diff < 60 then return "just now"
  elseif diff < 3600 then return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then return math.floor(diff / 3600) .. "h ago"
  else return math.floor(diff / 86400) .. "d ago"
  end
end

local function render_ui()
  if not ui_state.buf or not vim.api.nvim_buf_is_valid(ui_state.buf) then return end

  local sessions = list_sessions()
  ui_state.sessions = sessions

  local lines = {}
  for _, l in ipairs(HEADER) do table.insert(lines, l) end
  for _, l in ipairs(HELP_LINES) do table.insert(lines, l) end
  table.insert(lines, "  " .. string.rep("─", 68))

  if #sessions == 0 then
    table.insert(lines, "")
    table.insert(lines, "  No sessions saved yet. Press [s] to save the current session.")
    table.insert(lines, "")
  else
    table.insert(lines, "")
    for i, s in ipairs(sessions) do
      local idx = string.format("  %2d. ", i)
      local name_display = s.name:gsub("_", "/")
      local time_display = format_time(s.mtime)
      local pad = math.max(1, 52 - #name_display)
      local line = idx .. name_display .. string.rep(" ", pad) .. time_display
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end

  vim.api.nvim_buf_set_option(ui_state.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(ui_state.buf, "modifiable", false)

  local ns = vim.api.nvim_create_namespace("workmark_ui")
  vim.api.nvim_buf_clear_namespace(ui_state.buf, ns, 0, -1)

  for i = 0, #HEADER - 1 do
    vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkHeader", i, 0, -1)
  end
  
  vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkHelp", #HEADER, 0, -1)

  vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkSep", #HEADER + 1, 0, -1)

  local first_session_line = #HEADER + 3
  for i = 1, #sessions do
    local row = first_session_line + i - 1
    vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkIdx", row, 0, 6)
    vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkName", row, 6, 58)
    vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkTime", row, 58, -1)
  end

  return first_session_line
end

local function get_selected_session()
  if not ui_state.win or not vim.api.nvim_win_is_valid(ui_state.win) then return nil end
  local cursor = vim.api.nvim_win_get_cursor(ui_state.win)
  local row = cursor[1]
  local first_session_line = #HEADER + 4
  local idx = row - first_session_line + 1
  if idx >= 1 and idx <= #ui_state.sessions then
    return ui_state.sessions[idx]
  end
  return nil
end

local function close_ui()
  if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
    vim.api.nvim_win_close(ui_state.win, true)
  end
  ui_state.win = nil
  ui_state.buf = nil
end

local function set_keymaps()
  local buf = ui_state.buf
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  vim.keymap.set("n", "q", close_ui, opts)
  vim.keymap.set("n", "<Esc>", close_ui, opts)

  vim.keymap.set("n", "<CR>", function()
    local s = get_selected_session()
    if s then
      close_ui()
      M.load(s.name)
    end
  end, opts)

  vim.keymap.set("n", "d", function()
    local s = get_selected_session()
    if s then
      vim.ui.select({ "Yes", "No" }, {
        prompt = "Delete session '" .. s.name .. "'?",
      }, function(choice)
        if choice == "Yes" then
          M.delete(s.name)
          render_ui()
        end
      end)
    end
  end, opts)

  vim.keymap.set("n", "s", function()
    vim.ui.input({ prompt = "Session name: ", default = project_key() }, function(name)
      if name and name ~= "" then
        close_ui()
        M.save(name)
      end
    end)
  end, opts)

  vim.keymap.set("n", "r", function()
    local s = get_selected_session()
    if not s then return end
    vim.ui.input({ prompt = "Rename to: ", default = s.name }, function(new_name)
      if new_name and new_name ~= "" and new_name ~= s.name then
        local old_path = session_path(s.name)
        local new_path = session_path(new_name)
        vim.fn.rename(old_path, new_path)
        vim.notify("[workmark] Renamed to: " .. new_name, vim.log.levels.INFO)
        render_ui()
      end
    end)
  end, opts)
end

function M.open_ui()
  ensure_dir(M.config.sessions_dir)

  if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
    vim.api.nvim_set_current_win(ui_state.win)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "workmark")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local width = 76
  local height = 24
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " workmark ",
    title_pos = "center",
  })

  vim.api.nvim_win_set_option(win, "cursorline", true)
  vim.api.nvim_win_set_option(win, "wrap", false)

  ui_state.buf = buf
  ui_state.win = win

  local first_session_line = render_ui()

  -- Move cursor to first session
  local target = (first_session_line or (#HEADER + 4)) 
  local line_count = vim.api.nvim_buf_line_count(buf)
  if target <= line_count then
    vim.api.nvim_win_set_cursor(win, { target, 0 })
  end

  set_keymaps()

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
        vim.api.nvim_win_close(ui_state.win, true)
      end
      ui_state.win = nil
      ui_state.buf = nil
    end,
  })
end

function M.setup(user_config)
  if user_config then
    M.config = vim.tbl_deep_extend("force", M.config, user_config)
  end

  ensure_dir(M.config.sessions_dir)

  vim.api.nvim_set_hl(0, "WorkmarkHeader", { link = "Function",   default = true })
  vim.api.nvim_set_hl(0, "WorkmarkHelp",   { link = "Comment",    default = true })
  vim.api.nvim_set_hl(0, "WorkmarkSep",    { link = "NonText",    default = true })
  vim.api.nvim_set_hl(0, "WorkmarkIdx",    { link = "Number",     default = true })
  vim.api.nvim_set_hl(0, "WorkmarkName",   { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "WorkmarkTime",   { link = "Comment",    default = true })

  vim.api.nvim_create_user_command("WorkmarkSave", function(opts)
    M.save(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Save workmark session" })

  vim.api.nvim_create_user_command("WorkmarkLoad", function(opts)
    M.load(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Load workmark session" })

  vim.api.nvim_create_user_command("WorkmarkDelete", function(opts)
    M.delete(opts.args)
  end, { nargs = 1, desc = "Delete a workmark session" })

  vim.api.nvim_create_user_command("WorkmarkList", function()
    M.open_ui()
  end, { nargs = 0, desc = "Open workmark session browser" })

  if M.config.auto_save then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("workmark_autosave", { clear = true }),
      callback = function()
        M.save()
      end,
      desc = "workmark: auto-save session on exit",
    })
  end
end

return M
