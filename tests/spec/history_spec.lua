-- history_spec.lua -- unit tests for query history
local history = require("dadbod-grip.history")
local paths = require("dadbod-grip.paths")

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

local function contains(s, frag, msg)
  assert(type(s) == "string" and s:find(frag, 1, true),
    (msg or "") .. ": expected to contain '" .. frag .. "', got '" .. tostring(s) .. "'")
end

-- ── mock helpers ────────────────────────────────────────────────────────────

local mock_store = {}

local function setup_mock()
  mock_store = {}
  local orig_read_all = history._read_all
  local orig_write_all = history._write_all
  local orig_read_last = history._read_last
  local orig_append_one = history._append_one
  local orig_count_lines = history._count_lines
  local orig_notify = vim.notify
  -- Route every storage primitive through the same in-memory list so
  -- record()'s new append/dedup/amortized-trim paths are all exercised
  -- without touching disk. Note this mock is a plain passthrough: it does
  -- NOT reproduce the MAX_ENTRIES cap that M._read_all() enforces for real
  -- (see the "real file" section below for tests of that behavior).
  history._read_all = function() return mock_store end
  history._write_all = function(data) mock_store = data end
  history._read_last = function()
    if #mock_store == 0 then return nil end
    return mock_store[#mock_store]
  end
  history._append_one = function(entry) table.insert(mock_store, entry) end
  history._count_lines = function() return #mock_store end
  vim.notify = function() end
  return function()
    history._read_all = orig_read_all
    history._write_all = orig_write_all
    history._read_last = orig_read_last
    history._append_one = orig_append_one
    history._count_lines = orig_count_lines
    vim.notify = orig_notify
  end
end

local function with_mock(fn)
  local teardown = setup_mock()
  local ok, err = pcall(fn)
  teardown()
  if not ok then error(err) end
end

-- ── _redact_url ─────────────────────────────────────────────────────────────

test("_redact_url: strips password from postgresql URL", function()
  local result = history._redact_url("postgresql://myuser:s3cret@localhost/grip_test")
  eq(result, "postgresql://myuser:***@localhost/grip_test", "password redacted")
end)

test("_redact_url: strips password from mysql URL", function()
  local result = history._redact_url("mysql://root:hunter2@127.0.0.1:3306/testdb")
  eq(result, "mysql://root:***@127.0.0.1:3306/testdb", "password redacted")
end)

test("_redact_url: handles password with @ in it (greedy last-@)", function()
  local result = history._redact_url("mysql://user:p@ss@host/db")
  -- gsub matches first colon-to-@ segment
  contains(result, "***@", "should have redacted portion")
end)

test("_redact_url: no-op for sqlite URL (no auth)", function()
  local result = history._redact_url("sqlite:tests/seed_sqlite.db")
  eq(result, "sqlite:tests/seed_sqlite.db", "unchanged")
end)

test("_redact_url: no-op for duckdb memory URL", function()
  local result = history._redact_url("duckdb::memory:")
  eq(result, "duckdb::memory:", "unchanged")
end)

test("_redact_url: nil input returns empty string", function()
  eq(history._redact_url(nil), "", "nil becomes empty")
end)

-- ── record ──────────────────────────────────────────────────────────────────

test("record: stores entry with correct fields", function()
  with_mock(function()
    history.record({ sql = "SELECT 1", url = "sqlite:test.db", table_name = "users", type = "query" })
    eq(#mock_store, 1, "one entry")
    eq(mock_store[1].sql, "SELECT 1", "sql")
    eq(mock_store[1].url, "sqlite:test.db", "url")
    eq(mock_store[1]["table"], "users", "table")
    eq(mock_store[1].type, "query", "type")
    assert(type(mock_store[1].ts) == "number", "ts should be number")
  end)
end)

test("record: consecutive dedup updates timestamp", function()
  with_mock(function()
    mock_store = {{ sql = "SELECT 1", url = "sqlite:x.db", ts = 1000, type = "query" }}
    history.record({ sql = "SELECT 1", url = "sqlite:x.db" })
    eq(#mock_store, 1, "still one entry")
    assert(mock_store[1].ts > 1000, "timestamp should be updated")
  end)
end)

test("record: non-consecutive identical queries both stored", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT 1", url = "sqlite:x.db", ts = 1000, type = "query" },
      { sql = "SELECT 2", url = "sqlite:x.db", ts = 2000, type = "query" },
    }
    history.record({ sql = "SELECT 1", url = "sqlite:x.db" })
    eq(#mock_store, 3, "three entries (not deduped)")
  end)
end)

test("record: different SQL is not deduped", function()
  with_mock(function()
    mock_store = {{ sql = "SELECT 1", url = "sqlite:x.db", ts = 1000, type = "query" }}
    history.record({ sql = "SELECT 2", url = "sqlite:x.db" })
    eq(#mock_store, 2, "two entries")
  end)
end)

test("record: same SQL different URL is not deduped", function()
  with_mock(function()
    mock_store = {{ sql = "SELECT 1", url = "sqlite:a.db", ts = 1000, type = "query" }}
    history.record({ sql = "SELECT 1", url = "sqlite:b.db" })
    eq(#mock_store, 2, "two entries")
  end)
end)

test("record: empty SQL is ignored", function()
  with_mock(function()
    history.record({ sql = "", url = "sqlite:x.db" })
    eq(#mock_store, 0, "no entry for empty SQL")
  end)
end)

test("record: whitespace-only SQL is ignored", function()
  with_mock(function()
    history.record({ sql = "   \n\t  ", url = "sqlite:x.db" })
    eq(#mock_store, 0, "no entry for whitespace SQL")
  end)
end)

test("record: nil SQL is ignored", function()
  with_mock(function()
    history.record({ url = "sqlite:x.db" })
    eq(#mock_store, 0, "no entry for nil SQL")
  end)
end)

-- NOTE: the cap used to be enforced synchronously by record() itself, trimming
-- to 500 on every single write past the limit. It is now amortized: record()
-- only rewrites the whole file once it has overshot the cap by a comfortable
-- margin (see TRIM_THRESHOLD in history.lua), and the 500-entry cap is instead
-- enforced by M._read_all() at read time. This mock is a passthrough that does
-- not reproduce that read-time cap, so it can only demonstrate the "no eager
-- rewrite" half; the "reader never shows more than the cap, and the file gets
-- compacted back down once the threshold is crossed" half is covered by the
-- real-file tests further below, which exercise the unmocked implementation.
test("record: does not rewrite the file on every write past the cap (amortized)", function()
  with_mock(function()
    for i = 1, 500 do
      table.insert(mock_store, { sql = "Q" .. i, url = "x", ts = i, type = "query" })
    end
    history.record({ sql = "Q501", url = "x" })
    eq(#mock_store, 501, "grown past the cap without an immediate full rewrite")
    eq(mock_store[1].sql, "Q1", "oldest entry not yet trimmed")
    eq(mock_store[501].sql, "Q501", "newest appended at the end")
  end)
end)

test("record: redacts password in stored URL", function()
  with_mock(function()
    history.record({ sql = "SELECT 1", url = "postgresql://user:secret@host/db" })
    eq(mock_store[1].url, "postgresql://user:***@host/db", "password redacted")
  end)
end)

test("record: defaults type to query", function()
  with_mock(function()
    history.record({ sql = "SELECT 1", url = "x" })
    eq(mock_store[1].type, "query", "default type")
  end)
end)

-- ── list ────────────────────────────────────────────────────────────────────

test("list: returns newest first", function()
  with_mock(function()
    mock_store = {
      { sql = "first", url = "x", ts = 1, type = "query" },
      { sql = "second", url = "x", ts = 2, type = "query" },
      { sql = "third", url = "x", ts = 3, type = "query" },
    }
    local result = history.list()
    eq(result[1].sql, "third", "newest first")
    eq(result[3].sql, "first", "oldest last")
  end)
end)

test("list: respects limit parameter", function()
  with_mock(function()
    mock_store = {
      { sql = "Q1", url = "x", ts = 1, type = "query" },
      { sql = "Q2", url = "x", ts = 2, type = "query" },
      { sql = "Q3", url = "x", ts = 3, type = "query" },
    }
    local result = history.list(2)
    eq(#result, 2, "limited to 2")
    eq(result[1].sql, "Q3", "newest first")
    eq(result[2].sql, "Q2", "second newest")
  end)
end)

test("list: empty history returns empty", function()
  with_mock(function()
    local result = history.list()
    eq(#result, 0, "empty")
  end)
end)

-- ── clear ───────────────────────────────────────────────────────────────────

test("clear: removes all entries", function()
  with_mock(function()
    mock_store = {
      { sql = "Q1", url = "x", ts = 1, type = "query" },
      { sql = "Q2", url = "x", ts = 2, type = "query" },
    }
    history.clear()
    eq(#mock_store, 0, "empty after clear")
  end)
end)

-- ── round-trip ──────────────────────────────────────────────────────────────

test("round-trip: record then list returns same data", function()
  with_mock(function()
    history.record({ sql = "SELECT * FROM users", url = "sqlite:test.db", table_name = "users", type = "query" })
    history.record({ sql = "DELETE FROM orders WHERE id = 1", url = "sqlite:test.db", type = "dml" })
    local result = history.list()
    eq(#result, 2, "two entries")
    eq(result[1].sql, "DELETE FROM orders WHERE id = 1", "newest first")
    eq(result[1].type, "dml", "type preserved")
    eq(result[2].sql, "SELECT * FROM users", "oldest second")
    eq(result[2]["table"], "users", "table preserved")
  end)
end)

-- ── elapsed_ms ────────────────────────────────────────────────────────────────

test("record: stores elapsed_ms field", function()
  with_mock(function()
    history.record({ sql = "SELECT 1", url = "sqlite:x.db", elapsed_ms = 42 })
    eq(mock_store[1].elapsed_ms, 42, "elapsed_ms stored")
  end)
end)

test("record: elapsed_ms preserved through dedup", function()
  with_mock(function()
    mock_store = {{ sql = "SELECT 1", url = "sqlite:x.db", ts = 1000, type = "query", elapsed_ms = 100 }}
    history.record({ sql = "SELECT 1", url = "sqlite:x.db", elapsed_ms = 50 })
    eq(#mock_store, 1, "still one entry")
    eq(mock_store[1].elapsed_ms, 50, "elapsed_ms updated to latest")
  end)
end)

-- ── get_for_table ────────────────────────────────────────────────────────────

test("get_for_table: returns entries matching by table field", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM users", url = "x", ts = 1, type = "query", ["table"] = "users" },
      { sql = "SELECT * FROM orders", url = "x", ts = 2, type = "query", ["table"] = "orders" },
    }
    local result = history.get_for_table("users")
    eq(#result, 1, "one match")
    eq(result[1]["table"], "users", "correct entry returned")
  end)
end)

test("get_for_table: returns entries matching by sql content", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT name FROM users WHERE id = 1", url = "x", ts = 1, type = "query" },
      { sql = "SELECT * FROM orders", url = "x", ts = 2, type = "query" },
    }
    local result = history.get_for_table("users")
    eq(#result, 1, "one match by sql")
    contains(result[1].sql, "users", "sql contains table name")
  end)
end)

test("get_for_table: returns newest first", function()
  with_mock(function()
    mock_store = {
      { sql = "old users query", url = "x", ts = 1, type = "query", ["table"] = "users" },
      { sql = "new users query", url = "x", ts = 2, type = "query", ["table"] = "users" },
    }
    local result = history.get_for_table("users")
    eq(result[1].sql, "new users query", "newest first")
    eq(result[2].sql, "old users query", "oldest second")
  end)
end)

test("get_for_table: respects limit parameter", function()
  with_mock(function()
    mock_store = {
      { sql = "q1 users", url = "x", ts = 1, type = "query", ["table"] = "users" },
      { sql = "q2 users", url = "x", ts = 2, type = "query", ["table"] = "users" },
      { sql = "q3 users", url = "x", ts = 3, type = "query", ["table"] = "users" },
    }
    local result = history.get_for_table("users", 2)
    eq(#result, 2, "limited to 2")
    eq(result[1].sql, "q3 users", "newest first within limit")
  end)
end)

test("get_for_table: returns empty for nil table_name", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM users", url = "x", ts = 1, type = "query", ["table"] = "users" },
    }
    local result = history.get_for_table(nil)
    eq(#result, 0, "empty for nil")
  end)
end)

test("get_for_table: returns empty for empty table_name", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM users", url = "x", ts = 1, type = "query", ["table"] = "users" },
    }
    local result = history.get_for_table("")
    eq(#result, 0, "empty for empty string")
  end)
end)

test("get_for_table: does not return unrelated entries", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM orders", url = "x", ts = 1, type = "query", ["table"] = "orders" },
      { sql = "DELETE FROM products WHERE id = 5", url = "x", ts = 2, type = "dml" },
    }
    local result = history.get_for_table("users")
    eq(#result, 0, "no matches for unrelated table")
  end)
end)

test("get_for_table: sql match is case-insensitive", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM Users WHERE active = 1", url = "x", ts = 1, type = "query" },
    }
    local result = history.get_for_table("users")
    eq(#result, 1, "case-insensitive sql match")
  end)
end)

-- ── real file: amortized trim + read-time cap ───────────────────────────────
-- These exercise the actual M._read_all / M._append_one / M._count_lines /
-- M._write_all against a real (temp, isolated) file instead of the in-memory
-- mock above, because the MAX_ENTRIES cap now lives inside M._read_all() and
-- the mock is a plain passthrough that doesn't reproduce it.

--- Point paths.grip_dir() at an isolated temp directory for the duration of
--- fn, so history.lua's real file I/O never touches the project's own .grip.
local function with_real_file(fn)
  local tmp_dir = vim.fn.tempname() .. "_grip_history_test"
  local orig_grip_dir = paths.grip_dir
  local orig_notify = vim.notify
  paths.grip_dir = function() return tmp_dir end
  vim.notify = function() end
  local ok, err = pcall(fn, tmp_dir)
  paths.grip_dir = orig_grip_dir
  vim.notify = orig_notify
  vim.fn.delete(tmp_dir, "rf")
  if not ok then error(err) end
end

--- Write n well-formed entries directly (bypassing history.record) so tests
--- can seed a large starting file without n real record() calls each.
local function seed_file(tmp_dir, n)
  paths.ensure_dir(tmp_dir)
  local lines = {}
  for i = 1, n do
    table.insert(lines, vim.fn.json_encode({ sql = "Q" .. i, url = "x", ts = i, type = "query" }))
  end
  vim.fn.writefile(lines, tmp_dir .. "/history.jsonl")
end

test("real file: N consecutive records give the same list() shape as before", function()
  with_real_file(function()
    for i = 1, 20 do
      history.record({ sql = "SELECT " .. i, url = "sqlite:x.db", type = "query" })
    end
    -- A couple of consecutive dedups mixed in, same as ordinary interactive use.
    history.record({ sql = "SELECT 20", url = "sqlite:x.db", type = "query" })
    history.record({ sql = "SELECT 20", url = "sqlite:x.db", type = "query" })

    local result = history.list()
    eq(#result, 20, "dedup keeps count at 20, not 22")
    eq(result[1].sql, "SELECT 20", "newest first")
    eq(result[20].sql, "SELECT 1", "oldest last")
  end)
end)

test("real file: consecutive identical queries dedup to one line on disk", function()
  with_real_file(function(tmp_dir)
    history.record({ sql = "SELECT 1", url = "sqlite:x.db" })
    history.record({ sql = "SELECT 1", url = "sqlite:x.db" })
    history.record({ sql = "SELECT 1", url = "sqlite:x.db" })
    eq(#history.list(), 1, "deduped to one entry")
    eq(#vim.fn.readfile(tmp_dir .. "/history.jsonl"), 1, "one line on disk")
  end)
end)

test("real file: record() below the amortization threshold does not rewrite", function()
  with_real_file(function(tmp_dir)
    seed_file(tmp_dir, 500)
    history.record({ sql = "Q501", url = "x" })
    eq(#vim.fn.readfile(tmp_dir .. "/history.jsonl"), 501,
      "amortized: allowed to grow past the cap without an immediate rewrite")
    eq(#history.list(), 500, "list() still caps the view at 500 despite the on-disk overshoot")
  end)
end)

test("real file: on-disk overshoot is tolerated, but list() never exceeds the cap", function()
  with_real_file(function(tmp_dir)
    seed_file(tmp_dir, 600)
    eq(#vim.fn.readfile(tmp_dir .. "/history.jsonl"), 600, "600 lines physically present")
    local result = history.list()
    eq(#result, 500, "list() caps at 500 despite on-disk overshoot")
    eq(result[1].sql, "Q600", "newest first")
    eq(result[500].sql, "Q101", "oldest surviving entry is exactly the 500th newest")
  end)
end)

test("real file: crossing the amortization threshold compacts the file back to the cap", function()
  with_real_file(function(tmp_dir)
    seed_file(tmp_dir, 750)
    history.record({ sql = "Q751", url = "x" })
    eq(#vim.fn.readfile(tmp_dir .. "/history.jsonl"), 500,
      "file rewritten and trimmed back down to the cap once past the threshold")
    local result = history.list()
    eq(#result, 500, "list() reports exactly the cap")
    eq(result[1].sql, "Q751", "newest survives")
    eq(result[500].sql, "Q252", "oldest surviving is the 500th newest of 751")
  end)
end)

test("real file: malformed trailing line is skipped, not fatal", function()
  with_real_file(function(tmp_dir)
    paths.ensure_dir(tmp_dir)
    vim.fn.writefile({
      vim.fn.json_encode({ sql = "SELECT 1", url = "x", ts = 1, type = "query" }),
      vim.fn.json_encode({ sql = "SELECT 2", url = "x", ts = 2, type = "query" }),
      '{"sql": "SELECT 3", "url": "x", "ts": 3, "type": "quer', -- torn/partial write
    }, tmp_dir .. "/history.jsonl")
    local result = history.list()
    eq(#result, 2, "malformed trailing line skipped, valid lines still readable")
    eq(result[1].sql, "SELECT 2", "newest valid entry first")
  end)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nhistory_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
