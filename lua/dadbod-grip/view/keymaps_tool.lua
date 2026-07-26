-- view/keymaps_tool.lua: Tooling keymaps: DDL, pickers, watch, AI, pin.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local sql    = require("dadbod-grip.sql")
local db     = require("dadbod-grip.db")
local ui     = require("dadbod-grip.ui")

local M = {}

--- Everything that leaves the grid or changes the session: table diff, DDL,
--- schema browser, table/connection pickers, watch mode, write mode, open as
--- editable, query history, AI, pin and the result switcher.
function M.setup(bufnr, ctx)
  local open_info_float = ctx.open_info_float
  local update_badge = ctx.update_badge
  local start_watch = ctx.start_watch
  local stop_watch = ctx.stop_watch
  local map, kmap = ctx.map, ctx.kmap

  -- gD: diff against another table (picker with schema-overlap preview)
  kmap("grid_diff", function()
    local session_d = ctx.session()
    if not session_d then return end
    local st = session_d.state
    if not st.table_name then
      vim.notify("Diff requires a table name", vim.log.levels.INFO)
      return
    end
    local db_mod = require("dadbod-grip.db")
    local tables, err = db_mod.list_tables(st.url)
    if not tables then
      vim.notify("Grip: " .. (err or "failed to list tables"), vim.log.levels.ERROR)
      return
    end
    if #tables == 0 then
      vim.notify("Grip: no tables found", vim.log.levels.WARN)
      return
    end
    -- Fetch source table columns once for preview comparison
    local src_cols = db_mod.get_column_info(st.table_name, st.url) or {}
    local src_set = {}
    for _, col in ipairs(src_cols) do src_set[col.column_name] = true end

    require("dadbod-grip.grip_picker").open({
      title = "Diff " .. st.table_name .. " vs",
      items = tables,
      display = function(t)
        local icon = t.type == "view" and "○" or "●"
        return icon .. " " .. t.name
      end,
      preview = function(t)
        local other_cols = db_mod.get_column_info(t.name, st.url) or {}
        local other_set = {}
        for _, col in ipairs(other_cols) do other_set[col.column_name] = true end
        local lines = { st.table_name .. " ↔ " .. t.name, string.rep("─", 28), "" }
        local shared, only_src, only_other = {}, {}, {}
        for _, col in ipairs(src_cols) do
          if other_set[col.column_name] then
            table.insert(shared, "  = " .. col.column_name)
          else
            table.insert(only_src, "  - " .. col.column_name)
          end
        end
        for _, col in ipairs(other_cols) do
          if not src_set[col.column_name] then
            table.insert(only_other, "  + " .. col.column_name)
          end
        end
        if #shared > 0 then
          table.insert(lines, "Shared (" .. #shared .. "):")
          vim.list_extend(lines, shared)
          table.insert(lines, "")
        end
        if #only_other > 0 then
          table.insert(lines, "Only in " .. t.name .. ":")
          vim.list_extend(lines, only_other)
          table.insert(lines, "")
        end
        if #only_src > 0 then
          table.insert(lines, "Only in " .. st.table_name .. ":")
          vim.list_extend(lines, only_src)
        end
        return lines
      end,
      on_select = function(t)
        require("dadbod-grip.diff").open(st.table_name, t.name, st.url)
      end,
    })
  end, "Diff against table")

  -- gV: show CREATE TABLE DDL in floating window
  kmap("grid_show_ddl", function()
    local session_v = ctx.session()
    if not session_v then return end
    local tbl = session_v.state.table_name
    if not tbl then
      vim.notify("DDL view requires a table name", vim.log.levels.INFO)
      return
    end
    local url = session_v.state.url
    local grip_win = vim.api.nvim_get_current_win()

    local cols = db.get_column_info(tbl, url) or {}
    local pks  = db.get_primary_keys(tbl, url) or {}
    local fks  = (db.get_foreign_keys(tbl, url)) or {}
    local idxs = (db.get_indexes(tbl, url)) or {}

    local pk_set, fk_map = {}, {}
    for _, pk in ipairs(pks) do pk_set[pk] = true end
    for _, fk in ipairs(fks) do fk_map[fk.column] = fk end

    local lines = { "CREATE TABLE " .. sql.quote_ident(tbl) .. " (" }
    local col_lines = {}
    for _, col in ipairs(cols) do
      local chunk = "  " .. sql.quote_ident(col.column_name) .. " " .. (col.data_type or "TEXT")
      if col.column_default and col.column_default ~= "" then
        chunk = chunk .. " DEFAULT " .. col.column_default
      end
      if col.is_nullable == "NO" or col.is_nullable == false then
        chunk = chunk .. " NOT NULL"
      end
      local remarks = {}
      if pk_set[col.column_name] then table.insert(remarks, "PK") end
      if fk_map[col.column_name] then
        local fk = fk_map[col.column_name]
        table.insert(remarks, "FK -> " .. fk.ref_table .. "." .. fk.ref_column)
      end
      if #remarks > 0 then chunk = chunk .. "  -- " .. table.concat(remarks, ", ") end
      table.insert(col_lines, chunk)
    end
    if #pks > 0 then
      local pk_cols = {}
      for _, pk in ipairs(pks) do table.insert(pk_cols, sql.quote_ident(pk)) end
      table.insert(col_lines, "  PRIMARY KEY (" .. table.concat(pk_cols, ", ") .. ")")
    end
    for _, fk in ipairs(fks) do
      table.insert(col_lines, string.format(
        "  FOREIGN KEY (%s) REFERENCES %s(%s)",
        sql.quote_ident(fk.column), sql.quote_ident(fk.ref_table), sql.quote_ident(fk.ref_column)
      ))
    end
    for i, line in ipairs(col_lines) do
      table.insert(lines, i < #col_lines and (line .. ",") or line)
    end
    table.insert(lines, ");")

    local non_pk_idxs = {}
    for _, idx in ipairs(idxs) do
      if idx.type ~= "PRIMARY" then table.insert(non_pk_idxs, idx) end
    end
    if #non_pk_idxs > 0 then
      table.insert(lines, "")
      for _, idx in ipairs(non_pk_idxs) do
        local unique = idx.type == "UNIQUE" and "UNIQUE " or ""
        local idx_cols = type(idx.columns) == "table"
          and table.concat(idx.columns, ", ") or tostring(idx.columns or "")
        table.insert(lines, string.format(
          "CREATE %sINDEX %s ON %s (%s);",
          unique, sql.quote_ident(idx.name or "idx"), sql.quote_ident(tbl), idx_cols
        ))
      end
    end

    open_info_float(grip_win, lines, { title = " DDL: " .. tbl .. " ", filetype = "sql" })
  end, "Show CREATE TABLE DDL")

  -- gb: schema browser sidebar (toggle/focus)
  kmap("schema_browser", function()
    local schema = require("dadbod-grip.schema")
    local s = ctx.session()
    -- For file-as-table sessions, pass the file path so sidebar shows column schema
    local s_url = s and (s.file_path or s.url)
    schema.toggle(s_url)
  end, "Schema browser")

  -- go / gT / gt: table picker
  local function _pick_table()
    local picker = require("dadbod-grip.picker")
    local session = ctx.session()
    local s_url = session and session.url
    picker.pick_table(s_url, function(name)
      local grip = require("dadbod-grip")
      grip.open(name, s_url)
    end)
  end
  map("go", _pick_table, "Pick table")
  kmap("table_picker",     _pick_table, "Pick table")
  kmap("table_picker_alt", _pick_table, "Pick table")

  -- gC / <C-g>: switch database connection
  local function _pick_connection()
    require("dadbod-grip.connections").pick()
  end
  kmap("connections",     _pick_connection, "Switch connection")
  kmap("connections_alt", _pick_connection, "Switch connection")

  -- gW: toggle watch mode (auto-refresh on timer)
  kmap("grid_watch", function()
    local session = ctx.session()
    if not session then return end
    if session.watch_ms then
      stop_watch(bufnr)
      vim.notify("Watch mode off", vim.log.levels.INFO)
    else
      local ms = (session.opts and session.opts.watch_ms) or 5000
      start_watch(bufnr, ms)
      local secs = ms / 1000
      local label = secs == math.floor(secs) and tostring(math.floor(secs)) .. "s" or tostring(secs) .. "s"
      vim.notify("Watch mode on (" .. label .. ")", vim.log.levels.INFO)
    end
  end, "Toggle watch mode (auto-refresh)")

  -- g!: toggle write mode (file write-back on apply)
  kmap("grid_write_mode", function()
    local session = ctx.session()
    if not session then return end

    local file_path = session.file_path
    if not file_path then
      vim.notify("Write mode only applies to local file connections", vim.log.levels.INFO)
      return
    end
    if file_path:match("^https?://") then
      vim.notify("Remote files are read-only", vim.log.levels.INFO)
      return
    end

    if session.write_mode then
      -- Turning OFF: warn if staged changes exist
      local staged = session.state and (
        next(session.state.changes or {}) or
        next(session.state.deleted or {}) or
        next(session.state.inserted or {})
      )
      if staged then
        vim.notify("Staged changes exist. Apply (a) or undo (u) before disabling write mode.", vim.log.levels.WARN)
        return
      end
      session.write_mode = false
      update_badge(bufnr)
      vim.notify("Write mode off", vim.log.levels.INFO)
    else
      -- Turning ON: destructive-action confirm
      local short = vim.fn.fnamemodify(file_path, ":t")
      if not ui.confirm("Enable write mode for " .. short
        .. "? Applying edits will overwrite the file. (y/N): ") then
        return
      end
      session.write_mode = true
      update_badge(bufnr)
      vim.notify("Write mode on: edits will overwrite " .. short, vim.log.levels.INFO)
    end
  end, "Toggle write mode (overwrite file on apply)")

  -- gO: swap read-only query result to editable table
  kmap("grid_open_edit", function()
    local session = ctx.session()
    if not session then return end
    if not session.state.readonly then
      vim.notify("Already editable: i=edit  o=insert  d=delete", vim.log.levels.INFO)
      return
    end
    local grip = require("dadbod-grip")
    local s_url = session.url
    local current_win = vim.api.nvim_get_current_win()

    -- Try to auto-detect table name (check all sources)
    local detected = session.state.table_name
      or (session.query_spec and session.query_spec.table_name)
    local ambiguous = false

    -- Helper: extract table name from SQL (handles quoted and unquoted identifiers)
    local function extract_table_from_sql(sql_text)
      local flat = sql_text:gsub("\n", " ")
      -- Try quoted: FROM "table" or FROM `table`
      local quoted = flat:match('[Ff][Rr][Oo][Mm]%s+"([^"]+)"')
        or flat:match("[Ff][Rr][Oo][Mm]%s+`([^`]+)`")
      if quoted then return quoted end
      -- Unquoted: FROM table_name
      return flat:match("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)")
    end

    local function has_joins(sql_text)
      return sql_text:upper():match("JOIN%s") ~= nil
    end

    -- Fallback: parse base_sql from query spec (original unwrapped SQL)
    if not detected and session.query_spec and session.query_spec.base_sql then
      detected = extract_table_from_sql(session.query_spec.base_sql)
      ambiguous = has_joins(session.query_spec.base_sql)
    end

    -- Last resort: parse the wrapped query_sql (extract inner from _grip wrapper)
    if not detected then
      local sql_str = (session.query_sql or ""):gsub("\n", " ")
      local inner_sql = sql_str:match("%(%s*(.-)%s*%)%s+AS%s+_grip")
      local parse_target = inner_sql or sql_str
      detected = extract_table_from_sql(parse_target)
      ambiguous = ambiguous or has_joins(parse_target)
    end

    if detected and not ambiguous then
      vim.notify("Opening " .. detected .. " as editable table", vim.log.levels.INFO)
      grip.open(detected, s_url, { reuse_win = current_win })
    else
      -- Detection failed: show diagnostics so we can fix the root cause
      vim.notify(string.format(
        "gO: could not detect table\n table_name=%s | has_spec=%s | spec.table=%s\n spec.base_sql=%s\n query_sql=%s",
        tostring(session.state.table_name),
        tostring(session.query_spec ~= nil),
        tostring(session.query_spec and session.query_spec.table_name),
        tostring(session.query_spec and session.query_spec.base_sql and session.query_spec.base_sql:sub(1, 60)),
        tostring((session.query_sql or ""):sub(1, 60))
      ), vim.log.levels.WARN)
      -- Still offer picker as fallback
      local picker = require("dadbod-grip.picker")
      picker.pick_table(s_url, function(name)
        grip.open(name, s_url, { reuse_win = current_win })
      end)
    end
  end, "Open as editable table")

  -- gh: query history browser
  kmap("query_history", function()
    local hist = require("dadbod-grip.history")
    local session_h = ctx.session()
    local s_url = session_h and session_h.url
    hist.pick(function(sql_content)
      local query_pad = require("dadbod-grip.query_pad")
      query_pad.open(s_url, { initial_sql = sql_content })
    end)
  end, "Query history")

  -- A: AI SQL generation
  kmap("ai", function()
    local ai = require("dadbod-grip.ai")
    if not ai.is_enabled() then
      vim.notify("AI is disabled. Enable it in setup({ ai = { ... } })", vim.log.levels.INFO)
      return
    end
    local session_ai = ctx.session()
    local s_url = session_ai and session_ai.state.url
    if not s_url then
      s_url = require("dadbod-grip.db").get_url()
    end
    if not s_url then
      vim.notify("No database connection for AI", vim.log.levels.WARN)
      return
    end
    ai.ask(s_url)
  end, "AI SQL generation")

  kmap("grid_fill", function()
    local input = ui.input({ prompt = "Rows to generate: ", default = "1" })
    if not input then return end
    local n = tonumber(input)
    if not n or n < 1 then
      vim.notify("Enter a number >= 1", vim.log.levels.INFO)
      return
    end
    require("dadbod-grip").do_fill_rows(math.min(50, n))
  end, "AI-generated staged rows (GripFill)")

  -- gL: pin / unpin this result (exclude from auto-reuse by query pad)
  kmap("grid_pin", function()
    local session = ctx.session()
    if not session then return end
    if not session.pinned then
      -- Check pinned_max cap before pinning
      local limit = require("dadbod-grip").get_opts().pinned_max
      if limit then
        local count = 0
        ctx.each_session(function(_, s)
          if s.pinned then count = count + 1 end
        end)
        if count >= limit then
          vim.notify(string.format("Pin limit reached (%d). Unpin a result first (gL).", limit), vim.log.levels.WARN)
          return
        end
      end
      session.pinned = true
      -- Append [pinned] to buffer name
      local cur_name = vim.api.nvim_buf_get_name(bufnr)
      if not cur_name:match("%[pinned%]") then
        pcall(vim.api.nvim_buf_set_name, bufnr, cur_name .. " [pinned]")
      end
      vim.notify("Result pinned (gL to unpin, gJ to switch)", vim.log.levels.INFO)
    else
      session.pinned = false
      -- Remove [pinned] suffix from buffer name
      local cur_name = vim.api.nvim_buf_get_name(bufnr)
      pcall(vim.api.nvim_buf_set_name, bufnr, cur_name:gsub("%s*%[pinned%]", ""))
      vim.notify("Result unpinned", vim.log.levels.INFO)
    end
    update_badge(bufnr)
  end, "Pin/unpin result (exclude from auto-reuse)")

  -- gJ: result switcher: pick from all live grip grid sessions
  kmap("grid_results", function()
    local items = {}
    ctx.each_session(function(bnum, s)
      local win_id = nil
      for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(wid) == bnum then
          win_id = wid
          break
        end
      end
      if not win_id then return end  -- bufhidden=wipe: no window means already wiped
      local name = vim.api.nvim_buf_get_name(bnum)
      local short = name:match("^grip://(.+)$") or name
      local rows = s.total_rows
      local row_label = rows and (" [" .. rows .. " rows]") or ""
      local pin_label = s.pinned and " [pinned]" or ""
      local elapsed = s.elapsed_ms and (" " .. s.elapsed_ms .. "ms") or ""
      table.insert(items, {
        bufnr   = bnum,
        win_id  = win_id,
        label   = short:gsub("%s*%[pinned%]", "") .. row_label .. elapsed .. pin_label,
        pinned  = s.pinned,
      })
    end)
    if #items == 0 then
      vim.notify("No open results", vim.log.levels.INFO)
      return
    end
    -- Sort: pinned first, then by bufnr descending (most recent)
    table.sort(items, function(a, b)
      if a.pinned ~= b.pinned then return a.pinned end
      return a.bufnr > b.bufnr
    end)
    require("dadbod-grip.grip_picker").open({
      title = "Results",
      items = items,
      display = function(item) return (item.pinned and "" or " ") .. " " .. item.label end,
      on_select = function(item)
        vim.api.nvim_set_current_win(item.win_id)
      end,
    })
  end, "Result switcher (all open results)")
end

return M
