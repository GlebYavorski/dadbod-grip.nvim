-- view/keymaps_aggregate.lua: Aggregate, stats and export keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local sql    = require("dadbod-grip.sql")
local db     = require("dadbod-grip.db")
local qmod   = require("dadbod-grip.query")

local M = {}

--- Aggregates and column stats, table profile, clipboard export, EXPLAIN of
--- the current query and opening a URL from the cell under the cursor.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local open_info_float = ctx.open_info_float
  local kmap, kvmap, get_visual_rows = ctx.kmap, ctx.kvmap, ctx.get_visual_rows

  -- ga: aggregate current column (normal: all rows, visual: selected rows).
  -- row_indices = nil means "the whole column". Normal mode must NOT consult
  -- '< / '>: those marks hold the *previous* visual selection, so ga silently
  -- aggregated a stale range once the user had selected anything at all.
  local function aggregate_column(row_indices)
    local session_a = ctx.session()
    if not session_a or not session_a._render then return end
    local r = session_a._render
    local st_a = session_a.state

    -- Determine which column to aggregate from cursor position
    local col_name
    do
      local cell = view.get_cell(bufnr)
      if cell then
        col_name = cell.col_name
      else
        -- Cursor may be on header/type row: resolve via byte position
        local col_nr = vim.api.nvim_win_get_cursor(0)[2]
        local cols = r.visible_columns or st_a.columns
        if r.hdr_byte_positions then
          local snapped = view._snap_col(cols, r.hdr_byte_positions, col_nr)
          if snapped then col_name = snapped.col_name end
        end
      end
      if not col_name then
        vim.notify("Move cursor to a column first", vim.log.levels.INFO)
        return
      end
    end

    -- Collect values for the single column
    local targets = row_indices or r.ordered
    local values = {}
    local numeric_values = {}
    for _, row_idx in ipairs(targets) do
      local val = data.effective_value(st_a, row_idx, col_name)
      if val ~= nil then
        table.insert(values, val)
        local num = tonumber(val)
        if num then table.insert(numeric_values, num) end
      end
    end

    if #values == 0 then
      vim.notify("ga: " .. col_name .. ": no values", vim.log.levels.INFO)
      return
    end

    local agg_parts = { "ga: " .. col_name .. "  Count: " .. #values }
    if #numeric_values > 0 then
      local sum = 0
      local min_v, max_v = numeric_values[1], numeric_values[1]
      for _, n in ipairs(numeric_values) do
        sum = sum + n
        if n < min_v then min_v = n end
        if n > max_v then max_v = n end
      end
      local avg = sum / #numeric_values
      table.insert(agg_parts, string.format("Sum: %g", sum))
      table.insert(agg_parts, string.format("Avg: %.2f", avg))
      table.insert(agg_parts, string.format("Min: %g", min_v))
      table.insert(agg_parts, string.format("Max: %g", max_v))
    end

    vim.notify(table.concat(agg_parts, "  │  "), vim.log.levels.INFO)
  end

  kmap("grid_aggregate", function() aggregate_column(nil) end, "Aggregate current column")
  kvmap("grid_aggregate", function()
    local rows_a = get_visual_rows()
    if not rows_a or #rows_a == 0 then return end
    aggregate_column(rows_a)
  end, "Aggregate selected rows in column")

  -- gS: column statistics
  kmap("grid_col_stats", function()
    local session_cs = ctx.session()
    if not session_cs or not session_cs.state.table_name then
      vim.notify("Column stats requires a table name", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a column", vim.log.levels.INFO)
      return
    end
    local tbl = session_cs.state.table_name
    local col_q = sql.quote_ident(cell.col_name)
    local stats_sql = string.format(
      "SELECT COUNT(*) AS total, COUNT(DISTINCT %s) AS distinct_count, " ..
      "COUNT(*) - COUNT(%s) AS null_count, MIN(%s) AS min_val, MAX(%s) AS max_val " ..
      "FROM %s",
      col_q, col_q, col_q, col_q, sql.quote_ident(tbl)
    )
    local result, err = db.query(stats_sql, session_cs.state.url)
    if err then
      vim.notify("Stats query failed: " .. err, vim.log.levels.WARN)
      return
    end
    if not result or #result.rows == 0 then
      vim.notify("No stats returned", vim.log.levels.INFO)
      return
    end
    local row = result.rows[1]
    local info = {
      " " .. cell.col_name .. ": Column Statistics",
      " " .. string.rep("─", 40),
      "  Total:    " .. (row[1] or "?"),
      "  Distinct: " .. (row[2] or "?"),
      "  Nulls:    " .. (row[3] or "?"),
      "  Min:      " .. (row[4] or "NULL"),
      "  Max:      " .. (row[5] or "NULL"),
    }

    -- Try to get top 5 values
    local top_sql = string.format(
      "SELECT %s, COUNT(*) AS cnt FROM %s WHERE %s IS NOT NULL " ..
      "GROUP BY %s ORDER BY cnt DESC LIMIT 5",
      col_q, sql.quote_ident(tbl), col_q, col_q
    )
    local top_result = db.query(top_sql, session_cs.state.url)
    if top_result and #top_result.rows > 0 then
      table.insert(info, "")
      table.insert(info, "  Top values:")
      for _, r_top in ipairs(top_result.rows) do
        local val = r_top[1] or "?"
        local cnt = r_top[2] or "?"
        table.insert(info, "    " .. tostring(val):sub(1, 30) .. "  (" .. cnt .. ")")
      end
    end

    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, info, { title = " Column Stats " })
  end, "Column statistics")

  -- gR: table profile report
  kmap("grid_profile", function()
    local session_pr = ctx.session()
    if not session_pr or not session_pr.state.table_name then
      vim.notify("Profile requires a table name", vim.log.levels.INFO)
      return
    end
    local profile = require("dadbod-grip.profile")
    profile.open(session_pr.state.table_name, session_pr.state.url)
  end, "Table profile report")

  -- gE: export in multiple formats
  kmap("grid_export_clip", function()
    local session_e = ctx.session()
    if not session_e or not session_e._render then return end
    local st_e = session_e.state
    local r_e = session_e._render

    local formats = { "CSV", "TSV", "JSON", "SQL INSERT", "Markdown", "Grip Table" }
    vim.ui.select(formats, { prompt = "Export format:" }, function(choice)
      if not choice then return end

      local cols = st_e.columns
      local rows_data = {}
      for _, row_idx in ipairs(r_e.ordered) do
        local row = {}
        -- Indexed assignment: effective_value returns nil for NULL, and
        -- table.insert(row, nil) is a no-op that would shift columns left.
        -- Holes are intentional; consumers below iterate `for ci = 1, #cols`.
        for ci, col in ipairs(cols) do
          row[ci] = data.effective_value(st_e, row_idx, col)
        end
        table.insert(rows_data, row)
      end

      local FORMAT_IDS = {
        ["CSV"] = "csv", ["TSV"] = "tsv", ["JSON"] = "json",
        ["SQL INSERT"] = "sql", ["Markdown"] = "markdown", ["Grip Table"] = "grip",
      }
      -- Empty for a zero-row SQL INSERT export; still copied, as before.
      local output = table.concat(
        view._format_export(rows_data, cols, FORMAT_IDS[choice], st_e.table_name or "table_name"), "\n")

      if output then
        vim.fn.setreg("+", output)
        vim.notify("Exported " .. #rows_data .. " rows as " .. choice .. " to clipboard", vim.log.levels.INFO)
      end
    end)
  end, "Export in multiple formats")

  -- gQ: explain current query (shortcut for :GripExplain)
  kmap("grid_explain", function()
    local session_x = ctx.session()
    if not session_x then return end
    local explain_sql
    if session_x.query_spec then
      explain_sql = qmod.build_sql(session_x.query_spec)
    elseif session_x.query_sql then
      explain_sql = session_x.query_sql
    end
    if not explain_sql or explain_sql == "" then
      vim.notify("No query to explain", vim.log.levels.INFO)
      return
    end
    -- Table arg form: keeps multi-line SQL in one piece (see switch_view).
    vim.cmd({ cmd = "GripExplain", args = { explain_sql } })
  end, "Explain current query")

  -- gx: open URL in current cell (mirrors cell editor gx and Vim convention)
  kmap("grid_url_open", function()
    local cell = view.get_cell(bufnr)
    if not cell or not cell.value then
      vim.notify("No cell value", vim.log.levels.INFO)
      return
    end
    local val = tostring(cell.value):match("^%s*(.-)%s*$")
    if val:match("^https?://") or val:match("^ftp://") then
      if vim.ui.open then
        vim.ui.open(val)
      elseif vim.fn.has("mac") == 1 then
        vim.fn.jobstart({ "open", val }, { detach = true })
      else
        vim.fn.jobstart({ "xdg-open", val }, { detach = true })
      end
    else
      vim.notify("Not a URL", vim.log.levels.INFO)
    end
  end, "Open URL in current cell")
end

return M
