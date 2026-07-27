-- properties_spec.lua -- unit tests for the table properties float
-- Task 11: column/type/default alignment must use display width, not byte
-- length (#s), since column names, types and defaults come straight from the
-- database and may be non-ASCII.
local properties = require("dadbod-grip.properties")

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

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nproperties_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
