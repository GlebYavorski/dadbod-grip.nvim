-- properties_spec.lua -- unit tests for the table properties float
-- Task 11: column/type/default alignment must use display width, not byte
-- length (#s), since column names, types and defaults come straight from the
-- database and may be non-ASCII.
local properties = require("dadbod-grip.properties")
local db = require("dadbod-grip.db")
local ui = require("dadbod-grip.ui")

local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, frag, msg)
  assert(type(s) == "string" and s:find(frag, 1, true),
    (msg or "") .. ": expected to contain '" .. frag .. "', got '" .. tostring(s) .. "'")
end

local is_valid_utf8 = require("helpers").is_valid_utf8

local function mock_props(columns, indexes)
  return {
    table_name = "t",
    columns = columns,
    primary_keys = {},
    foreign_keys = {},
    indexes = indexes or {},
    row_estimate = 0,
    size_bytes = 0,
  }
end

-- ── ASCII: byte-identical to the pre-Task-11 rendering ───────────────────────

test("build_lines: ascii columns produce a clean aligned table", function()
  local props = mock_props({
    { column_name = "id", data_type = "integer", is_nullable = "NO", column_default = "" },
    { column_name = "name", data_type = "varchar(255)", is_nullable = "YES", column_default = "" },
  })
  local lines = properties._build_lines(props)
  local joined = table.concat(lines, "\n")
  contains(joined, "id", "has id column")
  contains(joined, "varchar(255)", "has type")
end)

test("build_lines: long ascii column name truncates with '~' (unchanged style)", function()
  local props = mock_props({
    { column_name = string.rep("a", 40), data_type = "text", is_nullable = "NO", column_default = "" },
  })
  local lines = properties._build_lines(props)
  local joined = table.concat(lines, "\n")
  contains(joined, "~", "long ascii name truncated with ~ marker")
  assert(not joined:find("…", 1, true), "must not use the ui.lua default ellipsis for ascii")
end)

-- ── non-ASCII: display width, character-safe truncation ─────────────────────

test("build_lines: cyrillic column name/type/default are not corrupted", function()
  local props = mock_props({
    { column_name = "идентификатор", data_type = "целое", is_nullable = "NO", column_default = "значение_по_умолчанию" },
  })
  local lines = properties._build_lines(props)
  local joined = table.concat(lines, "\n")
  for _, l in ipairs(lines) do
    assert(is_valid_utf8(l), "line is valid UTF-8: " .. l)
  end
  contains(joined, "~", "long cyrillic default was truncated")
end)

test("build_lines: CJK/emoji column values keep the table aligned", function()
  -- Old code sized/padded name+type via #s (byte length). "商品コード" is 15
  -- bytes but only 10 display cells; the byte-length column width leaves it
  -- 5 cells short of where the ASCII row ("id") lands, so the Null/Default
  -- fields drift out of alignment between rows.
  local props = mock_props({
    { column_name = "商品コード", data_type = "文字列型テキストデータ", is_nullable = "YES", column_default = "🍜デフォルト値です" },
    { column_name = "id", data_type = "integer", is_nullable = "NO", column_default = "" },
  })
  local lines = properties._build_lines(props)
  for _, l in ipairs(lines) do
    assert(is_valid_utf8(l), "line is valid UTF-8: " .. l)
  end

  local row1, row2
  for _, l in ipairs(lines) do
    if l:find("YES", 1, true) then row1 = l end
    if l:find("NO", 1, true) and l:find("id", 1, true) then row2 = l end
  end
  assert(row1 and row2, "found both column rows")

  -- The Null field ("YES"/"NO") must start at the same display column in
  -- both rows: Name and Type are padded to fixed widths ahead of it.
  local yes_col = vim.fn.strdisplaywidth(row1:sub(1, row1:find("YES", 1, true) - 1))
  local no_col  = vim.fn.strdisplaywidth(row2:sub(1, row2:find("NO", 1, true) - 1))
  eq(yes_col, no_col, "Null field aligned at the same display column across rows")
end)

test("build_lines: index name dot-fill alignment uses display width", function()
  -- Old code sized max_name and the dot-fill count from #idx.name (byte
  -- length). "индекс_короткий" is 16 cyrillic chars = 16 display cells but 31
  -- bytes, so the byte-length version reserves far more dot-fill than needed
  -- and the two index lines' "btree" markers land at different display
  -- columns (visibly misaligned); the fixed version puts both at the same
  -- column.
  local props = mock_props(
    { { column_name = "id", data_type = "integer", is_nullable = "NO", column_default = "" } },
    {
      { name = "индекс_короткий", type = "btree", columns = { "id" } },
      { name = "ix", type = "btree", columns = { "id" } },
    }
  )
  local lines = properties._build_lines(props)
  for _, l in ipairs(lines) do
    assert(is_valid_utf8(l), "line is valid UTF-8: " .. l)
  end
  local joined = table.concat(lines, "\n")
  contains(joined, "индекс_короткий", "cyrillic index name intact")
  contains(joined, "....", "dot-fill still renders")

  local idx_lines = {}
  for _, l in ipairs(lines) do
    if l:find("btree", 1, true) then table.insert(idx_lines, l) end
  end
  eq(#idx_lines, 2, "found both index lines")
  local first_col
  for _, l in ipairs(idx_lines) do
    local byte_pos = l:find("btree", 1, true)
    local col = vim.fn.strdisplaywidth(l:sub(1, byte_pos - 1))
    first_col = first_col or col
    eq(col, first_col, "index type ('btree') aligned at the same display column: " .. l)
  end
end)

-- ── M.open: R/+/T deterministic buffer cleanup (task 22 item 5) ─────────────
-- Before this fix, R/+/T called a bare nvim_win_close and left the buffer to
-- WinLeave's deferred (vim.schedule) reclaim, which the blocking ddl.lua
-- prompt opened right after can starve until the prompt returns (worst case:
-- the buffer leaks for as long as the prompt is up). They now call the same
-- close() dismiss_float already hands back, which deletes the buffer
-- synchronously -- so it must already be gone by the time the keymap
-- callback returns, well before any prompt gets a chance to block anything.

local function mock_open_db()
  local orig = {
    get_column_info  = db.get_column_info,
    get_primary_keys = db.get_primary_keys,
    get_foreign_keys = db.get_foreign_keys,
    get_indexes      = db.get_indexes,
    get_table_stats  = db.get_table_stats,
  }
  db.get_column_info  = function() return { { column_name = "id", data_type = "integer", is_nullable = "NO", column_default = "" } } end
  db.get_primary_keys = function() return {} end
  db.get_foreign_keys = function() return {} end
  db.get_indexes      = function() return {} end
  db.get_table_stats  = function() return { row_estimate = 0, size_bytes = 0 } end
  return function()
    for k, v in pairs(orig) do db[k] = v end
  end
end

local function press_key(bufnr, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs and m.callback then
      m.callback()
      return true
    end
  end
  return false
end

--- Open the properties float and put the cursor on the "id" column row --
--- the R keymap's cursor_column() needs that to resolve to a real column.
--- db/ui are mocked by the caller; this only opens the float.
local function open_props_for_keymap_test()
  local test_props = {
    table_name = "t",
    columns = { { column_name = "id", data_type = "integer", is_nullable = "NO", column_default = "" } },
    primary_keys = {}, foreign_keys = {}, indexes = {}, row_estimate = 0, size_bytes = 0,
  }
  local _, _, col_line_map = properties._build_lines(test_props)
  local id_row
  for row, col_name in pairs(col_line_map) do
    if col_name == "id" then id_row = row end
  end
  assert(id_row, "test setup: 'id' column row not found in build_lines output")

  local win, buf = properties.open("t", "test://url")
  vim.api.nvim_win_set_cursor(win, { id_row, 0 })
  return win, buf
end

--- Run one R/+/T keymap test end to end: mock db + a cancelling ui.input
--- (so the ddl prompt returns immediately without touching the database),
--- open the float, press the key, and hand (win, buf) back for assertions.
local function run_keymap_test(lhs)
  local restore_db = mock_open_db()
  local orig_input = ui.input
  ui.input = function() return nil end  -- simulate <Esc> on the ddl prompt

  local win, buf = open_props_for_keymap_test()
  local pressed = press_key(buf, lhs)

  ui.input = orig_input
  restore_db()

  assert(pressed, lhs .. " keymap must be registered")
  return win, buf
end

test("R keymap: buffer is deleted deterministically, not left to WinLeave", function()
  local win, buf = run_keymap_test("R")
  eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
  eq(vim.api.nvim_buf_is_valid(buf), false, "float buffer deleted synchronously")
end)

test("+ keymap: buffer is deleted deterministically, not left to WinLeave", function()
  local win, buf = run_keymap_test("+")
  eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
  eq(vim.api.nvim_buf_is_valid(buf), false, "float buffer deleted synchronously")
end)

test("T keymap: buffer is deleted deterministically, not left to WinLeave", function()
  local win, buf = run_keymap_test("T")
  eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
  eq(vim.api.nvim_buf_is_valid(buf), false, "float buffer deleted synchronously")
end)

test("D keymap: buffer is deleted deterministically, not left to WinLeave", function()
  local win, buf = run_keymap_test("D")
  eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
  eq(vim.api.nvim_buf_is_valid(buf), false, "float buffer deleted synchronously")

  -- Unlike R/+/T, D's callback goes straight into ddl.drop_column's
  -- destructive_confirm, which opens (and enters) its own float right after
  -- close() runs -- close it here so this test leaves no window behind for
  -- whatever the runner executes next.
  local confirm_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(confirm_win) and vim.api.nvim_win_get_config(confirm_win).relative ~= "" then
    local confirm_buf = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_win_close, confirm_win, true)
    pcall(vim.api.nvim_buf_delete, confirm_buf, { force = true })
  end
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nproperties_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
