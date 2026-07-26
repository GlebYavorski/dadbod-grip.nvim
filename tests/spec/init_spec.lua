-- init_spec.lua: unit tests for resolve_query routing, is_queryable_file and
-- the welcome screen (open_welcome)
local grip = require("dadbod-grip")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. pattern .. "'")
end

-- ── is_queryable_file: path prefix ───────────────────────────────────────────

test("is_queryable_file: absolute path with .parquet", function()
  eq(grip._is_queryable_file("/data/sales.parquet"), true)
end)

test("is_queryable_file: tilde path with .csv", function()
  eq(grip._is_queryable_file("~/data/report.csv"), true)
end)

test("is_queryable_file: dot-slash with .json", function()
  eq(grip._is_queryable_file("./data.json"), true)
end)

test("is_queryable_file: dot-dot-slash with .tsv", function()
  eq(grip._is_queryable_file("../up/data.tsv"), true)
end)

test("is_queryable_file: bare name is not a file path", function()
  eq(grip._is_queryable_file("tablename"), false)
end)

-- ── is_queryable_file: extension ─────────────────────────────────────────────

test("is_queryable_file: .parquet", function()
  eq(grip._is_queryable_file("/x.parquet"), true)
end)

test("is_queryable_file: .csv", function()
  eq(grip._is_queryable_file("/x.csv"), true)
end)

test("is_queryable_file: .json", function()
  eq(grip._is_queryable_file("/x.json"), true)
end)

test("is_queryable_file: .xlsx", function()
  eq(grip._is_queryable_file("/x.xlsx"), true)
end)

test("is_queryable_file: .ndjson", function()
  eq(grip._is_queryable_file("/x.ndjson"), true)
end)

test("is_queryable_file: .jsonl", function()
  eq(grip._is_queryable_file("/x.jsonl"), true)
end)

test("is_queryable_file: .txt not supported", function()
  eq(grip._is_queryable_file("/x.txt"), false)
end)

-- ── is_queryable_file: case insensitivity ────────────────────────────────────

test("is_queryable_file: uppercase .CSV", function()
  eq(grip._is_queryable_file("/path/file.CSV"), true)
end)

-- ── resolve_query: routing ───────────────────────────────────────────────────

test("resolve_query: table name returns table spec", function()
  local spec, tbl = grip._resolve_query("users", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "users", "table_name")
end)

test("resolve_query: SELECT extracts table name from FROM clause", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "table_name should be extracted from SELECT")
end)

test("resolve_query: WITH returns raw spec", function()
  local spec = grip._resolve_query("WITH cte AS (SELECT 1) SELECT * FROM cte", 50)
  assert(spec, "spec should not be nil")
end)

test("resolve_query: TABLE extracts table name", function()
  local spec, tbl = grip._resolve_query("TABLE orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "TABLE should extract table name")
end)

test("resolve_query: nil with expand stub returns table spec", function()
  local orig = vim.fn.expand
  vim.fn.expand = function() return "users" end
  local spec, tbl = grip._resolve_query(nil, 50)
  vim.fn.expand = orig
  assert(spec, "spec should not be nil")
  eq(tbl, "users", "table_name from cword")
end)

test("resolve_query: empty string with empty expand returns nil + error", function()
  local orig = vim.fn.expand
  vim.fn.expand = function() return "" end
  local spec, err = grip._resolve_query("", 50)
  vim.fn.expand = orig
  eq(spec, nil, "spec should be nil")
  assert(err, "should return error message")
end)

test("resolve_query: lowercase 'select' returns raw spec", function()
  local spec = grip._resolve_query("select 1", 50)
  assert(spec, "spec should not be nil")
end)

-- ── resolve_query: table extraction from SELECT/TABLE ────────────────────────

test("resolve_query: SELECT with double-quoted PascalCase table", function()
  local spec, tbl = grip._resolve_query('SELECT * FROM "Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "Participant", "should unquote double-quoted table name")
end)

test("resolve_query: SELECT with backtick-quoted table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM `my_table`", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "my_table", "should unquote backtick-quoted table name")
end)

test("resolve_query: SELECT with schema-qualified table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM public.users", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "public.users", "should extract schema-qualified table name")
end)

test("resolve_query: SELECT with schema-qualified quoted table", function()
  local spec, tbl = grip._resolve_query('SELECT * FROM "public"."Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "public.Participant", "should unquote schema-qualified quoted table")
end)

test("resolve_query: SELECT with WHERE clause still extracts table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM orders WHERE id = 1", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "should extract table when WHERE clause follows")
end)

test("resolve_query: SELECT with JOIN returns nil table (ambiguous)", function()
  local spec, tbl = grip._resolve_query("SELECT a.*, b.* FROM users a JOIN orders b ON a.id = b.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for JOINs")
end)

test("resolve_query: SELECT with LEFT JOIN returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for LEFT JOINs")
end)

test("resolve_query: SELECT with comma-join returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM users, orders WHERE users.id = orders.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for comma-joins")
end)

test("resolve_query: SELECT from subquery returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM (SELECT 1) t", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for subqueries")
end)

test("resolve_query: select 1 (no FROM) returns nil table", function()
  local spec, tbl = grip._resolve_query("select 1", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil when no FROM clause")
end)

test("resolve_query: TABLE with quoted name extracts unquoted", function()
  local spec, tbl = grip._resolve_query('TABLE "Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "Participant", "TABLE should unquote table name")
end)

test("resolve_query: multiline SELECT extracts table", function()
  local spec, tbl = grip._resolve_query("SELECT *\nFROM orders\nWHERE id > 0", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "should extract table from multiline SELECT")
end)

-- ── resolve_query: file-as-table ─────────────────────────────────────────────

test("resolve_query: readable file path returns raw spec", function()
  local orig_readable = vim.fn.filereadable
  local orig_fnamemodify = vim.fn.fnamemodify
  vim.fn.filereadable = function() return 1 end
  vim.fn.fnamemodify = function(p) return p end
  local spec, tbl, fpath = grip._resolve_query("/data/sales.parquet", 50)
  vim.fn.filereadable = orig_readable
  vim.fn.fnamemodify = orig_fnamemodify
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil")
  eq(fpath, "/data/sales.parquet", "file_path")
end)

test("resolve_query: file path with single quote is escaped", function()
  local orig_readable = vim.fn.filereadable
  local orig_fnamemodify = vim.fn.fnamemodify
  vim.fn.filereadable = function() return 1 end
  vim.fn.fnamemodify = function(p) return p end
  local spec = grip._resolve_query("/data/it's.csv", 50)
  vim.fn.filereadable = orig_readable
  vim.fn.fnamemodify = orig_fnamemodify
  assert(spec, "spec should not be nil")
  -- The SQL in the spec should have escaped single quote
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "it''s", "single quote should be escaped")
end)

-- ── is_queryable_file: URL detection ────────────────────────────────────────

test("is_queryable_file: https URL with .csv", function()
  eq(grip._is_queryable_file("https://example.com/data.csv"), true)
end)

test("is_queryable_file: http URL with .parquet", function()
  eq(grip._is_queryable_file("http://example.com/data.parquet"), true)
end)

test("is_queryable_file: https URL with .json", function()
  eq(grip._is_queryable_file("https://example.com/data.json"), true)
end)

test("is_queryable_file: https URL with .ndjson", function()
  eq(grip._is_queryable_file("https://example.com/data.ndjson"), true)
end)

test("is_queryable_file: https URL with .xlsx", function()
  eq(grip._is_queryable_file("https://example.com/data.xlsx"), true)
end)

test("is_queryable_file: https URL with unsupported extension", function()
  eq(grip._is_queryable_file("https://example.com/page.html"), false)
end)

test("is_queryable_file: URL with query string stripped for extension check", function()
  eq(grip._is_queryable_file("https://example.com/data.csv?token=abc"), true)
end)

test("is_queryable_file: URL with fragment stripped for extension check", function()
  eq(grip._is_queryable_file("https://example.com/data.parquet#row=5"), true)
end)

test("is_queryable_file: URL case insensitive", function()
  eq(grip._is_queryable_file("https://example.com/DATA.CSV"), true)
end)

test("is_queryable_file: bare https not a file", function()
  eq(grip._is_queryable_file("https://example.com/"), false)
end)

-- ── resolve_query: URL-as-table ─────────────────────────────────────────────

test("resolve_query: https URL returns raw spec with URL as file_path", function()
  local spec, tbl, fpath = grip._resolve_query("https://example.com/data.csv", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil for URL queries")
  eq(fpath, "https://example.com/data.csv", "file_path should be the URL")
end)

test("resolve_query: URL SQL contains the URL in FROM clause", function()
  local spec = grip._resolve_query("https://example.com/data.parquet", 50)
  assert(spec, "spec should not be nil")
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "https://example.com/data.parquet", "SQL should contain the URL")
end)

test("resolve_query: URL with single quote is escaped", function()
  local spec = grip._resolve_query("https://example.com/it's.csv", 50)
  assert(spec, "spec should not be nil")
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "it''s", "single quote should be escaped")
end)

test("resolve_query: URL does not call filereadable", function()
  local called = false
  local orig = vim.fn.filereadable
  vim.fn.filereadable = function() called = true; return 0 end
  local spec = grip._resolve_query("https://example.com/data.csv", 50)
  vim.fn.filereadable = orig
  assert(spec, "spec should not be nil")
  eq(called, false, "filereadable should not be called for URLs")
end)

-- ── open_welcome: extmark highlights ─────────────────────────────────────────
-- open_welcome() applies its syntax highlights inside vim.schedule (so they
-- survive the FileType autocmd -- see init.lua), and headless tests have no
-- UI loop driving that callback on their own. Rather than exporting a
-- renderer to call directly, these drive vim.schedule for real and vim.wait
-- on the extmarks actually showing up: that exercises the exact scheduled
-- path :Grip and :GripHome run, not a reimplementation of it.

local WELCOME_NS = vim.api.nvim_create_namespace("grip_welcome")

--- Open the welcome screen for real and wait (bounded, on the actual
--- condition -- not a fixed sleep) for its scheduled highlight pass to run.
--- @return integer buf, table marks  (nvim_buf_get_extmarks with details)
local function open_welcome_and_wait()
  grip.open_welcome()
  local buf = vim.api.nvim_get_current_buf()
  local marks
  local ok = vim.wait(1000, function()
    marks = vim.api.nvim_buf_get_extmarks(buf, WELCOME_NS, 0, -1, { details = true })
    return #marks > 0
  end, 10)
  assert(ok, "welcome highlight scheduling did not fire within 1s")
  return buf, marks
end

test("open_welcome: highlights every logo/legend/keymap region once scheduled", function()
  local buf, marks = open_welcome_and_wait()
  local by_group = {}
  for _, m in ipairs(marks) do
    local g = m[4].hl_group
    by_group[g] = (by_group[g] or 0) + 1
  end
  eq(#marks, 62, "total extmarks")
  eq(by_group.Comment, 9, "section headers + tagline")
  eq(by_group.Special, 3, "logo box lines (╔ ║ ╚)")
  eq(by_group.Title, 1, "dadbod-grip title")
  eq(by_group.Statement, 4, ":Grip command examples")
  eq(by_group.Identifier, 42, "keymap columns + --flags")
  eq(by_group.GripModified, 1, "legend: modified")
  eq(by_group.GripInserted, 1, "legend: inserted")
  eq(by_group.GripDeleted, 1, "legend: deleted")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

test("open_welcome: title and legend marks carry the right range and priority", function()
  local buf, marks = open_welcome_and_wait()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local function find(hl_group)
    for _, m in ipairs(marks) do
      if m[4].hl_group == hl_group then return m end
    end
  end

  -- Title: "dadbod-grip" through end-of-line on the logo row, at the default
  -- extmark priority (nothing overrides it -- see hl_range() in init.lua).
  -- The line contains the version string, so its length isn't hardcoded here:
  -- it's read back from the buffer, the same way hl_range() computed it.
  local title = find("Title")
  assert(title, "Title mark exists")
  local title_line = lines[title[2] + 1]
  local vs = title_line:find("dadbod-grip", 1, true)
  assert(vs, "title line contains the plugin name")
  eq(title[3], vs - 1, "title starts where the name does")
  eq(title[4].end_col, #title_line, "title runs to end of line")
  eq(title[4].priority, 4096, "default extmark priority")

  -- Legend phrases sit at explicit priority 200 so they win over syntax
  -- highlighting on the same line (see hl_phrase() in init.lua).
  for _, spec in ipairs({
    { group = "GripModified", phrase = "violet = modified" },
    { group = "GripInserted", phrase = "green = inserted" },
    { group = "GripDeleted",  phrase = "red = deleted" },
  }) do
    local m = find(spec.group)
    assert(m, spec.group .. " mark exists")
    local legend_line = lines[m[2] + 1]
    local s, e = legend_line:find(spec.phrase, 1, true)
    assert(s, spec.group .. " phrase found in its line")
    eq(m[3], s - 1, spec.group .. " start col")
    eq(m[4].end_col, e, spec.group .. " end col")
    eq(m[4].priority, 200, spec.group .. " priority")
  end

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\ninit_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
