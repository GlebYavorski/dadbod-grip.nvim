-- sqlserver_schema_spec.lua: parse-level tests for the sqlserver schema queries
-- (get_schema_batch / get_column_info) and for the adapters.run_cmd_async contract.
--
-- The schema tests mirror the pg/mysql/sqlite get_schema_batch tests in
-- adapter_spec.lua: feed sqlcmd's tab-separated output through the real parser
-- and assert on the structure, without a server.
local sqlserver = require("dadbod-grip.adapters.sqlserver")
local adapters = require("dadbod-grip.adapters")

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

local function contains(s, needle, msg)
  assert(s:find(needle, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. needle .. "'")
end

-- ── mock helpers ─────────────────────────────────────────────────────────────

local function with_system_mock(stdout, stderr, code, fn)
  local orig = vim.system
  vim.system = function(_args, _opts, cb)
    local r = { stdout = stdout, stderr = stderr or "", code = code or 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
end

local function capture_system_args(stdout, fn)
  local captured
  local orig = vim.system
  vim.system = function(args, _opts, cb)
    captured = args
    local r = { stdout = stdout or "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return captured
end

local function with_executable(fn)
  local orig = vim.fn.executable
  vim.fn.executable = function() return 1 end
  local ok, err = pcall(fn)
  vim.fn.executable = orig
  if not ok then error(err) end
end

local URL = "sqlserver://sa:pw@localhost:1433/grip_test"

local function lines(t)
  return table.concat(t, "\n") .. "\n"
end

-- ── get_schema_batch ─────────────────────────────────────────────────────────

local BATCH_OUT = lines({
  "table_name\tcolumn_name\tdata_type\tis_nullable",
  "----------\t-----------\t---------\t-----------",
  "users\tid\tint\tNO",
  "users\tname\tnvarchar(100)\tNO",
  "users\temail\tnvarchar(255)\tYES",
  "orders\tid\tint\tNO",
  "orders\ttotal\tdecimal(10,2)\tNO",
  "",
  "(5 rows affected)",
})

test("sqlserver get_schema_batch: groups columns by table", function()
  local result
  with_executable(function()
    with_system_mock(BATCH_OUT, "", 0, function()
      result = sqlserver.get_schema_batch(URL)
    end)
  end)
  assert(result, "result must not be nil")
  assert(result["users"], "must have users key")
  assert(result["orders"], "must have orders key")
  eq(#result["users"], 3, "users has 3 columns")
  eq(#result["orders"], 2, "orders has 2 columns")
  eq(result["users"][2].column_name, "name", "users second column")
  eq(result["users"][2].data_type, "nvarchar(100)", "length suffix survives")
  eq(result["users"][2].is_nullable, "NO", "name is NOT NULL")
  eq(result["users"][3].is_nullable, "YES", "email is nullable")
  eq(result["orders"][2].data_type, "decimal(10,2)", "precision,scale suffix survives")
end)

test("sqlserver get_schema_batch: (N rows affected) is not a column row", function()
  local result
  with_executable(function()
    with_system_mock(BATCH_OUT, "", 0, function()
      result = sqlserver.get_schema_batch(URL)
    end)
  end)
  for tname, cols in pairs(result) do
    contains(tname, "", "table name")
    assert(not tname:find("rows affected", 1, true), "row-count line leaked in as a table: " .. tname)
    for _, c in ipairs(cols) do
      assert(not c.column_name:find("rows affected", 1, true),
        "row-count line leaked in as a column of " .. tname)
    end
  end
  eq(#result["orders"], 2, "orders still has exactly 2 columns")
end)

test("sqlserver get_schema_batch: failure returns nil", function()
  local result = "unset"
  with_executable(function()
    with_system_mock("", "Login failed for user 'sa'.", 1, function()
      result = sqlserver.get_schema_batch(URL)
    end)
  end)
  eq(result, nil, "must return nil when sqlcmd fails")
end)

-- A server error is not a result grid: with -b sqlcmd exits non-zero and prints
-- "Msg 208, ..." on stdout, and the parser must never be handed that as data.
test("sqlserver get_schema_batch: Msg error text is not parsed as a grid", function()
  local msg = lines({
    "Msg 208, Level 16, State 1, Server abc, Line 2",
    "Invalid object name 'INFORMATION_SCHEMA.COLUMNS'.",
  })
  local result = "unset"
  with_executable(function()
    with_system_mock(msg, "", 1, function()
      result = sqlserver.get_schema_batch(URL)
    end)
  end)
  eq(result, nil, "error text must not become a schema table")
end)

test("sqlserver query: Msg error text on stdout becomes err, not columns", function()
  local msg = lines({
    "Msg 208, Level 16, State 1, Server abc, Line 2",
    "Invalid object name 'dbo.no_such_table'.",
  })
  local result, err = "unset", nil
  with_executable(function()
    with_system_mock(msg, "", 1, function()
      result, err = sqlserver.query("SELECT * FROM dbo.no_such_table", URL)
    end)
  end)
  eq(result, nil, "no result on error")
  assert(err, "err must be set")
  contains(err, "Msg 208", "err carries the server message")
  contains(err, "Invalid object name", "err carries the detail line")
end)

test("sqlserver execute: server error is an error, not a successful 0 rows", function()
  local msg = lines({
    "Msg 3726, Level 16, State 1, Server abc, Line 1",
    "Could not drop object 'dbo.users' because it is referenced by a FOREIGN KEY constraint.",
  })
  local result, err = "unset", nil
  with_executable(function()
    with_system_mock(msg, "", 1, function()
      result, err = sqlserver.execute('DROP TABLE "dbo"."users"', URL)
    end)
  end)
  eq(result, nil, "no result on error")
  assert(err, "err must be set")
  contains(err, "Msg 3726", "err carries the server message")
end)

test("sqlserver: sqlcmd runs with -b (without it the server exits 0 on errors)", function()
  with_executable(function()
    for _, case in ipairs({
      { "query", function() sqlserver.query("SELECT 1", URL) end },
      { "execute", function() sqlserver.execute("UPDATE dbo.users SET age = 1", URL) end },
    }) do
      local args = capture_system_args("id\n--\n1\n", case[2])
      local found = false
      for _, a in ipairs(args) do
        if a == "-b" then found = true end
      end
      assert(found, case[1] .. " must pass -b: " .. table.concat(args, " "))
    end
  end)
end)

-- ── get_column_info ─────────────────────────────────────────────────────────

local COLUMN_INFO_OUT = lines({
  "COLUMN_NAME\tdata_type\tIS_NULLABLE\tcolumn_default\t",
  "-----------\t---------\t-----------\t--------------\t-",
  "id\tint\tNO\t\t",
  "name\tnvarchar(100)\tNO\t\t",
  "body\tnvarchar(max)\tYES\t\t",
  "created_at\tdatetime2\tNO\t(sysutcdatetime())\t",
  "",
})

test("sqlserver get_column_info: parses name, type, nullability and default", function()
  local cols, err
  with_executable(function()
    with_system_mock(COLUMN_INFO_OUT, "", 0, function()
      cols, err = sqlserver.get_column_info("dbo.long_values", URL)
    end)
  end)
  assert(not err, "should not error: " .. tostring(err))
  eq(#cols, 4, "four columns")
  eq(cols[1].column_name, "id", "first column name")
  eq(cols[1].data_type, "int", "int has no suffix")
  eq(cols[2].data_type, "nvarchar(100)", "length suffix")
  eq(cols[3].data_type, "nvarchar(max)", "MAX types keep (max)")
  eq(cols[3].is_nullable, "YES", "nullable")
  eq(cols[4].column_default, "(sysutcdatetime())", "default expression")
end)

test("sqlserver get_column_info: schema-qualified name is split into schema + table", function()
  local args
  with_executable(function()
    args = capture_system_args(COLUMN_INFO_OUT, function()
      sqlserver.get_column_info("sales.invoices", URL)
    end)
  end)
  local sent = args[#args]
  contains(sent, "TABLE_SCHEMA = 'sales'", "schema from the qualified name")
  contains(sent, "TABLE_NAME = 'invoices'", "bare table name")
end)

test("sqlserver get_column_info: unqualified name defaults to dbo", function()
  local args
  with_executable(function()
    args = capture_system_args(COLUMN_INFO_OUT, function()
      sqlserver.get_column_info("users", URL)
    end)
  end)
  contains(args[#args], "TABLE_SCHEMA = 'dbo'", "dbo is the default schema")
end)

-- MAX types report CHARACTER_MAXIMUM_LENGTH = -1, which the plain `> 0` guard
-- silently dropped; both statements must ask for the (max) arm.
test("sqlserver: batch and column_info both handle CHARACTER_MAXIMUM_LENGTH = -1", function()
  with_executable(function()
    local batch_args = capture_system_args(BATCH_OUT, function()
      sqlserver.get_schema_batch(URL)
    end)
    local info_args = capture_system_args(COLUMN_INFO_OUT, function()
      sqlserver.get_column_info("users", URL)
    end)
    for _, case in ipairs({ { "get_schema_batch", batch_args }, { "get_column_info", info_args } }) do
      local sent = case[2][#case[2]]
      contains(sent, "CHARACTER_MAXIMUM_LENGTH = -1", case[1] .. " must special-case MAX types")
      contains(sent, "'(max)'", case[1] .. " must render them as (max)")
    end
  end)
end)

-- The two statements must stay in sync: a table read from the batch and the same
-- table read per-table have to report the same data_type string.
test("sqlserver: batch and column_info share one data_type expression", function()
  local function type_expr(sent)
    return sent:match("(DATA_TYPE %+.-END AS data_type)")
  end
  with_executable(function()
    local batch_args = capture_system_args(BATCH_OUT, function()
      sqlserver.get_schema_batch(URL)
    end)
    local info_args = capture_system_args(COLUMN_INFO_OUT, function()
      sqlserver.get_column_info("users", URL)
    end)
    local a = type_expr(batch_args[#batch_args])
    local b = type_expr(info_args[#info_args])
    assert(a, "batch statement must contain the data_type expression")
    assert(b, "column_info statement must contain the data_type expression")
    eq(a, b, "the two data_type expressions must be identical")
  end)
end)

-- ── adapters.run_cmd_async contract ─────────────────────────────────────────

test("run_cmd_async: delivery is asynchronous even when on_exit fires inline", function()
  local calls = 0
  local orig = vim.system
  vim.system = function(_args, _opts, cb)
    cb({ stdout = "out", stderr = "", code = 0 })
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters.run_cmd_async({ "true" }, 1000, function() calls = calls + 1 end)
    -- vim.schedule defers to the main loop, so nothing may have run yet.
    eq(calls, 0, "callback must not run inside run_cmd_async")
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "callback must run exactly once")
  end)
  vim.system = orig
  if not ok then error(err) end
end)

test("run_cmd_async: a process that never exits still gets a timeout answer", function()
  local got
  local orig = vim.system
  local grace = adapters._exit_grace_ms
  vim.system = function(_args, _opts, _cb)
    -- Never invokes on_exit: the watchdog is the only way out.
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters._exit_grace_ms = 20
    local calls = 0
    adapters.run_cmd_async({ "hang" }, 10, function(stdout, stderr, code)
      calls = calls + 1
      got = { stdout = stdout, stderr = stderr, code = code }
    end)
    vim.wait(2000, function() return got ~= nil end, 1)
    assert(got, "watchdog must deliver a callback")
    eq(got.code, 1, "timeout reports a failed exit")
    eq(got.stderr, "command timed out", "same message as the blocking path")
    eq(got.stdout, "", "no output")
    eq(calls, 1, "exactly one delivery")
  end)
  adapters._exit_grace_ms = grace
  vim.system = orig
  if not ok then error(err) end
end)

test("run_cmd_async: a late on_exit after the watchdog does not deliver twice", function()
  local captured_on_exit
  local calls = 0
  local orig = vim.system
  local grace = adapters._exit_grace_ms
  vim.system = function(_args, _opts, cb)
    captured_on_exit = cb
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters._exit_grace_ms = 20
    adapters.run_cmd_async({ "slow" }, 10, function() calls = calls + 1 end)
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "watchdog delivered once")
    captured_on_exit({ stdout = "late", stderr = "", code = 0 })
    vim.wait(100, function() return calls > 1 end, 1)
    eq(calls, 1, "a late on_exit must be ignored")
  end)
  adapters._exit_grace_ms = grace
  vim.system = orig
  if not ok then error(err) end
end)

-- Two mechanisms keep this true (stopping the timer and the deliver-once flag),
-- so it only goes red when both are gone -- which is the point: the callback
-- must not fire a second time however the implementation is rearranged.
test("run_cmd_async: the watchdog is cancelled on normal delivery", function()
  local calls = 0
  local orig = vim.system
  local grace = adapters._exit_grace_ms
  vim.system = function(_args, _opts, cb)
    vim.schedule(function() cb({ stdout = "ok", stderr = "", code = 0 }) end)
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters._exit_grace_ms = 20
    adapters.run_cmd_async({ "true" }, 10, function() calls = calls + 1 end)
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "delivered once")
    -- Well past the watchdog deadline: a live timer would deliver again.
    vim.wait(300, function() return calls > 1 end, 1)
    eq(calls, 1, "watchdog must not fire after a normal delivery")
  end)
  adapters._exit_grace_ms = grace
  vim.system = orig
  if not ok then error(err) end
end)

test("run_cmd_async: a spawn failure is reported once, asynchronously", function()
  local calls, got = 0, nil
  local orig = vim.system
  vim.system = function() error("ENOENT: no such file or directory") end
  local ok, err = pcall(function()
    adapters.run_cmd_async({ "nope" }, 50, function(_stdout, stderr, code)
      calls = calls + 1
      got = { stderr = stderr, code = code }
    end)
    eq(calls, 0, "spawn failure must not call back inline")
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "exactly one delivery")
    eq(got.code, 1, "reported as a failed exit")
    contains(got.stderr, "ENOENT", "carries the spawn error")
  end)
  vim.system = orig
  if not ok then error(err) end
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nsqlserver_schema_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
