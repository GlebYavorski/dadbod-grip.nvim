-- view/keymaps_schema.lua: Table structure keymaps: diff, DDL, schema browser.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local sql    = require("dadbod-grip.sql")
local db     = require("dadbod-grip.db")

local M = {}

--- Look at the shape of the data rather than the data: diff this table's
--- columns against another's, render its CREATE TABLE, open the schema sidebar.
function M.setup(bufnr, ctx)
  local open_info_float = ctx.open_info_float
  local kmap = ctx.kmap

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
end

return M
