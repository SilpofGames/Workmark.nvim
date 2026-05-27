-- workmark.nvim
-- Session manager with Telescope, statusline & notes support
-- Pure Lua, zero required dependencies

local M = {}

M.config = {
  sessions_dir = vim.fn.stdpath("data") .. "/workmark_sessions",
  notes_dir    = vim.fn.stdpath("data") .. "/workmark_notes",
  auto_save    = true,
  max_sessions = 20,
  statusline   = true,
}

M._active_session = nil

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then vim.fn.mkdir(path, "p") end
end

local function sanitize(name)
  return name:gsub("[^%w%-_]", "_")
end

local function session_path(name)
  return M.config.sessions_dir .. "/" .. sanitize(name) .. ".vim"
end

local function note_path(name)
  return M.config.notes_dir .. "/" .. sanitize(name) .. ".txt"
end

local function project_key()
  return sanitize(vim.fn.getcwd())
end

local function format_time(mtime)
  local diff = os.time() - mtime
  if diff < 60        then return "just now"
  elseif diff < 3600  then return math.floor(diff / 60)    .. "m ago"
  elseif diff < 86400 then return math.floor(diff / 3600)  .. "h ago"
  else                     return math.floor(diff / 86400) .. "d ago"
  end
end

local function list_sessions()
  ensure_dir(M.config.sessions_dir)
  local sessions = {}
  local files = vim.fn.glob(M.config.sessions_dir .. "/*.vim", false, true)
  for _, filepath in ipairs(files) do
    local name  = vim.fn.fnamemodify(filepath, ":t:r")
    local mtime = vim.fn.getftime(filepath)
    local note  = ""
    local np    = note_path(name)
    if vim.fn.filereadable(np) == 1 then
      note = table.concat(vim.fn.readfile(np), " "):sub(1, 60)
    end
    table.insert(sessions, { name = name, path = filepath, mtime = mtime, note = note })
  end
  table.sort(sessions, function(a, b) return a.mtime > b.mtime end)
  return sessions
end

-- ─── Core ────────────────────────────────────────────────────────────────────

function M.save(name)
  ensure_dir(M.config.sessions_dir)
  name = name or project_key()
  local path = session_path(name)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ok, bt = pcall(vim.api.nvim_buf_get_option, buf, "buftype")
    if ok and bt ~= "" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local ok, err = pcall(function()
    vim.cmd("mksession! " .. vim.fn.fnameescape(path))
  end)

  if ok then
    M._active_session = name
    vim.notify("[workmark] Session saved: " .. name, vim.log.levels.INFO)
    M._enforce_max(name)
  else
    vim.notify("[workmark] Failed to save: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M._enforce_max(skip_name)
  local sessions = list_sessions()
  if #sessions <= M.config.max_sessions then return end
  for i = M.config.max_sessions + 1, #sessions do
    if sessions[i].name ~= sanitize(skip_name or "") then
      vim.fn.delete(sessions[i].path)
      vim.fn.delete(note_path(sessions[i].name))
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
    M._active_session = name
    vim.notify("[workmark] Session loaded: " .. name, vim.log.levels.INFO)
  else
    vim.notify("[workmark] Failed to load: " .. tostring(err), vim.log.levels.ERROR)
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
  vim.fn.delete(note_path(name))
  if M._active_session == name then M._active_session = nil end
  vim.notify("[workmark] Session deleted: " .. name, vim.log.levels.INFO)
end

-- ─── FEATURE 1: Notes ────────────────────────────────────────────────────────

function M.edit_note(name)
  name = name or M._active_session or project_key()
  ensure_dir(M.config.notes_dir)
  local np = note_path(name)
  local current = ""
  if vim.fn.filereadable(np) == 1 then
    current = table.concat(vim.fn.readfile(np), " ")
  end

  vim.ui.input({
    prompt  = "Note for [" .. name .. "]: ",
    default = current,
  }, function(input)
    if input == nil then return end
    vim.fn.writefile({ input }, np)
    vim.notify("[workmark] Note saved for: " .. name, vim.log.levels.INFO)
  end)
end

function M.get_note(name)
  if not name then return "" end
  local np = note_path(name)
  if vim.fn.filereadable(np) == 0 then return "" end
  return table.concat(vim.fn.readfile(np), " ")
end

-- ─── FEATURE 2: Statusline ───────────────────────────────────────────────────

-- Plain string for manual statusline setups
-- Usage: set statusline+=\ %{luaeval('require("workmark").statusline()')}
function M.statusline()
  if not M._active_session then return "" end
  return " [" .. M._active_session:gsub("_", "/"):sub(1, 30) .. "]"
end

-- Ready-to-use lualine component table
-- Usage: add require("workmark").lualine_component() to your lualine sections
function M.lualine_component()
  return {
    function()
      if not M._active_session then return "" end
      return " " .. M._active_session:gsub("_", "/"):sub(1, 30)
    end,
    cond  = function() return M._active_session ~= nil end,
    color = { fg = "#7aa2f7", gui = "bold" },
    padding = { left = 1, right = 1 },
  }
end

-- ─── FEATURE 3: Telescope ────────────────────────────────────────────────────

function M.telescope(opts)
  local has_telescope = pcall(require, "telescope")
  if not has_telescope then
    vim.notify("[workmark] Telescope not found, using built-in UI.", vim.log.levels.WARN)
    M.open_ui()
    return
  end

  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  opts = opts or {}
  local sessions = list_sessions()

  local displayer = entry_display.create({
    separator = "  ",
    items = {
      { width = 36 },
      { width = 9  },
      { remaining = true },
    },
  })

  local function make_display(entry)
    local s = entry.value
    local active_mark = (M._active_session == s.name) and "● " or "  "
    return displayer({
      { active_mark .. s.name:gsub("_", "/"), "TelescopeResultsIdentifier" },
      { format_time(s.mtime),                 "TelescopeResultsComment"    },
      { s.note,                               "TelescopeResultsComment"    },
    })
  end

  pickers.new(opts, {
    prompt_title = "Workmark Sessions",
    finder = finders.new_table({
      results = sessions,
      entry_maker = function(s)
        return {
          value   = s,
          display = make_display,
          ordinal = s.name .. " " .. s.note,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(prompt_bufnr, map)
      -- <CR>: load
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel then M.load(sel.value.name) end
      end)

      -- <C-d>: delete
      map({ "i", "n" }, "<C-d>", function()
        local sel = action_state.get_selected_entry()
        if not sel then return end
        vim.ui.select({ "Yes", "No" }, {
          prompt = "Delete '" .. sel.value.name .. "'?",
        }, function(choice)
          if choice == "Yes" then
            M.delete(sel.value.name)
            actions.close(prompt_bufnr)
            vim.schedule(M.telescope)
          end
        end)
      end)

      -- <C-n>: edit note
      map({ "i", "n" }, "<C-n>", function()
        local sel = action_state.get_selected_entry()
        if not sel then return end
        actions.close(prompt_bufnr)
        M.edit_note(sel.value.name)
      end)

      -- <C-s>: save new session
      map({ "i", "n" }, "<C-s>", function()
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "Save session as: ", default = project_key() }, function(name)
          if name and name ~= "" then M.save(name) end
        end)
      end)

      return true
    end,
  }):find()
end

-- ─── Floating Window UI ──────────────────────────────────────────────────────

local ui_state = { buf = nil, win = nil, sessions = {} }

local HELP = "  [Enter] Load  [d] Delete  [s] Save  [r] Rename  [n] Note  [q] Close"

local HEADER = {
  "  ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███╗   ███╗ █████╗ ██████╗ ██╗  ██╗",
  "  ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝████╗ ████║██╔══██╗██╔══██╗██║ ██╔╝",
  "  ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ██╔████╔██║███████║██████╔╝█████╔╝ ",
  "  ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ██║╚██╔╝██║██╔══██║██╔══██╗██╔═██╗ ",
  "  ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██╗",
  "   ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝",
  "",
}

local function render_ui()
  if not ui_state.buf or not vim.api.nvim_buf_is_valid(ui_state.buf) then return end

  local sessions = list_sessions()
  ui_state.sessions = sessions

  local lines = {}
  for _, l in ipairs(HEADER) do table.insert(lines, l) end
  table.insert(lines, HELP)
  table.insert(lines, "  " .. string.rep("─", 72))

  if #sessions == 0 then
    table.insert(lines, "")
    table.insert(lines, "  No sessions yet. Press [s] to save the current session.")
    table.insert(lines, "")
  else
    table.insert(lines, "")
    for i, s in ipairs(sessions) do
      local active  = (M._active_session == s.name) and "● " or "  "
      local idx     = string.format("  %2d. ", i)
      local name_d  = active .. s.name:gsub("_", "/")
      local time_d  = format_time(s.mtime)
      local note_d  = s.note ~= "" and ("  » " .. s.note:sub(1, 16)) or ""
      local pad     = math.max(1, 44 - #name_d)
      table.insert(lines, idx .. name_d .. string.rep(" ", pad) .. time_d .. note_d)
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
  vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkHelp", #HEADER,     0, -1)
  vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkSep",  #HEADER + 1, 0, -1)

  local first = #HEADER + 3
  for i = 1, #sessions do
    local row = first + i - 1
    vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkIdx",  row, 0,  6)
    vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkName", row, 6,  52)
    vim.api.nvim_buf_add_highlight(ui_state.buf, ns, "WorkmarkTime", row, 52, -1)
  end

  return first
end

local function get_selected_session()
  if not ui_state.win or not vim.api.nvim_win_is_valid(ui_state.win) then return nil end
  local row   = vim.api.nvim_win_get_cursor(ui_state.win)[1]
  local first = #HEADER + 4
  local idx   = row - first + 1
  if idx >= 1 and idx <= #ui_state.sessions then return ui_state.sessions[idx] end
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
  local buf  = ui_state.buf
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  vim.keymap.set("n", "q",     close_ui, opts)
  vim.keymap.set("n", "<Esc>", close_ui, opts)

  vim.keymap.set("n", "<CR>", function()
    local s = get_selected_session()
    if s then close_ui(); M.load(s.name) end
  end, opts)

  vim.keymap.set("n", "d", function()
    local s = get_selected_session()
    if not s then return end
    vim.ui.select({ "Yes", "No" }, { prompt = "Delete '" .. s.name .. "'?" },
      function(choice)
        if choice == "Yes" then M.delete(s.name); render_ui() end
      end)
  end, opts)

  vim.keymap.set("n", "s", function()
    vim.ui.input({ prompt = "Save as: ", default = project_key() }, function(name)
      if name and name ~= "" then close_ui(); M.save(name) end
    end)
  end, opts)

  vim.keymap.set("n", "r", function()
    local s = get_selected_session()
    if not s then return end
    vim.ui.input({ prompt = "Rename to: ", default = s.name }, function(new_name)
      if new_name and new_name ~= "" and new_name ~= s.name then
        vim.fn.rename(session_path(s.name), session_path(new_name))
        local old_np = note_path(s.name)
        if vim.fn.filereadable(old_np) == 1 then
          vim.fn.rename(old_np, note_path(new_name))
        end
        if M._active_session == s.name then M._active_session = new_name end
        vim.notify("[workmark] Renamed to: " .. new_name, vim.log.levels.INFO)
        render_ui()
      end
    end)
  end, opts)

  vim.keymap.set("n", "n", function()
    local s = get_selected_session()
    if not s then return end
    close_ui()
    M.edit_note(s.name)
  end, opts)
end

function M.open_ui()
  ensure_dir(M.config.sessions_dir)

  if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
    vim.api.nvim_set_current_win(ui_state.win)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype",    "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden",  "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype",   "workmark")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local width  = 80
  local height = 26
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col,
    width = width, height = height,
    style = "minimal", border = "rounded",
    title = " workmark ", title_pos = "center",
  })

  vim.api.nvim_win_set_option(win, "cursorline", true)
  vim.api.nvim_win_set_option(win, "wrap",       false)

  ui_state.buf = buf
  ui_state.win = win

  local first = render_ui()
  local target = first or (#HEADER + 4)
  if target <= vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_win_set_cursor(win, { target, 0 })
  end

  set_keymaps()

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf, once = true,
    callback = function()
      if ui_state.win and vim.api.nvim_win_is_valid(ui_state.win) then
        vim.api.nvim_win_close(ui_state.win, true)
      end
      ui_state.win = nil
      ui_state.buf = nil
    end,
  })
end

-- ─── Setup ───────────────────────────────────────────────────────────────────

function M.setup(user_config)
  if user_config then
    M.config = vim.tbl_deep_extend("force", M.config, user_config)
  end

  ensure_dir(M.config.sessions_dir)
  ensure_dir(M.config.notes_dir)

  vim.api.nvim_set_hl(0, "WorkmarkHeader", { link = "Function",   default = true })
  vim.api.nvim_set_hl(0, "WorkmarkHelp",   { link = "Comment",    default = true })
  vim.api.nvim_set_hl(0, "WorkmarkSep",    { link = "NonText",    default = true })
  vim.api.nvim_set_hl(0, "WorkmarkIdx",    { link = "Number",     default = true })
  vim.api.nvim_set_hl(0, "WorkmarkName",   { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "WorkmarkTime",   { link = "Comment",    default = true })

  vim.api.nvim_create_user_command("WorkmarkSave", function(o)
    M.save(o.args ~= "" and o.args or nil)
  end, { nargs = "?", desc = "Save workmark session" })

  vim.api.nvim_create_user_command("WorkmarkLoad", function(o)
    M.load(o.args ~= "" and o.args or nil)
  end, { nargs = "?", desc = "Load workmark session" })

  vim.api.nvim_create_user_command("WorkmarkDelete", function(o)
    M.delete(o.args)
  end, { nargs = 1, desc = "Delete a workmark session" })

  vim.api.nvim_create_user_command("WorkmarkList", function()
    M.open_ui()
  end, { nargs = 0, desc = "Open workmark session browser" })

  vim.api.nvim_create_user_command("WorkmarkTelescope", function()
    M.telescope()
  end, { nargs = 0, desc = "Open workmark in Telescope" })

  vim.api.nvim_create_user_command("WorkmarkNote", function(o)
    M.edit_note(o.args ~= "" and o.args or nil)
  end, { nargs = "?", desc = "Edit note for a session" })

  if M.config.auto_save then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group    = vim.api.nvim_create_augroup("workmark_autosave", { clear = true }),
      callback = function() M.save() end,
      desc     = "workmark: auto-save on exit",
    })
  end
end

return M
