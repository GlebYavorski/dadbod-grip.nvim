-- adapter_spec.lua: unit tests for adapter URL parsing, output parsing, SQL rewriting
local mysql = require("dadbod-grip.adapters.mysql")
local sqlite = require("dadbod-grip.adapters.sqlite")
local duckdb = require("dadbod-grip.adapters.duckdb")
local pg = require("dadbod-grip.adapters.postgresql")
local adapters = require("dadbod-grip.adapters")
local sqlserver = require("dadbod-grip.adapters.sqlserver")

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

local function has_arg(args, flag, msg)
  for _, a in ipairs(args) do
    if a == flag then return end
  end
  error((msg or "") .. ": expected args to contain '" .. flag .. "'")
end

local function last_arg(args)
  return args[#args]
end

-- ── mock helpers ──────────────────────────────────────────────────────────────

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

-- ── MySQL parse_url ──────────────────────────────────────────────────────────

test("mysql parse_url: full URL parses all fields", function()
  local r = mysql._parse_url("mysql://alice:secret@db.host:3307/mydb")
  eq(r.user, "alice", "user")
  eq(r.pass, "secret", "pass")
  eq(r.host, "db.host", "host")
  eq(r.port, "3307", "port")
  eq(r.dbname, "mydb", "dbname")
end)

test("mysql parse_url: URL without port defaults to 3306", function()
  local r = mysql._parse_url("mysql://user:pass@host/db")
  eq(r.port, "3306", "port")
  eq(r.host, "host", "host")
end)

test("mysql parse_url: URL without auth", function()
  local r = mysql._parse_url("mysql://localhost:3306/mydb")
  eq(r.user, nil, "user")
  eq(r.pass, nil, "pass")
  eq(r.host, "localhost", "host")
  eq(r.dbname, "mydb", "dbname")
end)

test("mysql parse_url: @ in password uses last-@ rule", function()
  local r = mysql._parse_url("mysql://user:p@ss@host/db")
  eq(r.user, "user", "user")
  eq(r.pass, "p@ss", "pass")
  eq(r.host, "host", "host")
  eq(r.dbname, "db", "dbname")
end)

test("mysql parse_url: URL without dbname", function()
  local r = mysql._parse_url("mysql://user:pass@host:3306")
  eq(r.dbname, nil, "dbname should be nil")
  eq(r.host, "host", "host")
end)

test("mysql parse_url: mariadb scheme", function()
  local r = mysql._parse_url("mariadb://user:pass@host/db")
  eq(r.user, "user", "user")
  eq(r.dbname, "db", "dbname")
end)

test("mysql parse_url: empty string returns nil", function()
  local r = mysql._parse_url("")
  eq(r, nil, "empty")
end)

test("mysql parse_url: malformed returns nil", function()
  local r = mysql._parse_url("just-a-host")
  eq(r, nil, "malformed")
end)

-- ── SQLite extract_path ──────────────────────────────────────────────────────

test("sqlite extract_path: relative path", function()
  eq(sqlite._extract_path("sqlite:relative/path.db"), "relative/path.db")
end)

test("sqlite extract_path: absolute path", function()
  eq(sqlite._extract_path("sqlite:/absolute/path.db"), "/absolute/path.db")
end)

test("sqlite extract_path: triple-slash absolute", function()
  eq(sqlite._extract_path("sqlite:///absolute/path.db"), "/absolute/path.db")
end)

test("sqlite extract_path: tilde expansion", function()
  local home = os.getenv("HOME") or ""
  eq(sqlite._extract_path("sqlite:~/test.db"), home .. "/test.db")
end)

test("sqlite extract_path: bare sqlite: returns nil", function()
  eq(sqlite._extract_path("sqlite:"), nil)
end)

test("sqlite extract_path: non-sqlite scheme returns nil", function()
  eq(sqlite._extract_path("postgres://localhost/db"), nil)
end)

-- ── DuckDB extract_path ──────────────────────────────────────────────────────

test("duckdb extract_path: relative path", function()
  eq(duckdb._extract_path("duckdb:path.db"), "path.db")
end)

test("duckdb extract_path: absolute path", function()
  eq(duckdb._extract_path("duckdb:/absolute.db"), "/absolute.db")
end)

test("duckdb extract_path: triple-slash absolute", function()
  eq(duckdb._extract_path("duckdb:///absolute"), "/absolute")
end)

test("duckdb extract_path: memory returns :memory:", function()
  eq(duckdb._extract_path("duckdb::memory:"), ":memory:")
end)

test("duckdb extract_path: bare duckdb: returns :memory:", function()
  eq(duckdb._extract_path("duckdb:"), ":memory:")
end)

-- ── PostgreSQL affected-row parsing ──────────────────────────────────────────

test("pg execute: UPDATE 5 parses affected rows", function()
  with_executable(function()
    with_system_mock("UPDATE 5\n", "", 0, function()
      local result, err = pg.execute("UPDATE users SET x=1", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 5, "affected")
    end)
  end)
end)

test("pg execute: INSERT 0 1 parses affected rows", function()
  with_executable(function()
    with_system_mock("INSERT 0 1\n", "", 0, function()
      local result, err = pg.execute("INSERT INTO t VALUES (1)", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 1, "affected")
    end)
  end)
end)

test("pg execute: DELETE 3 parses affected rows", function()
  with_executable(function()
    with_system_mock("DELETE 3\n", "", 0, function()
      local result, err = pg.execute("DELETE FROM t WHERE x=1", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
    end)
  end)
end)

test("pg execute: empty stdout parses as 0 affected", function()
  with_executable(function()
    with_system_mock("", "", 0, function()
      local result, err = pg.execute("DO $$ BEGIN END $$", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 0, "affected")
    end)
  end)
end)

-- ── PostgreSQL .psqlrc bypass ────────────────────────────────────────────

test("pg query: passes -X to skip .psqlrc", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      pg.query("SELECT 1", "postgresql://localhost/db")
    end)
    has_arg(args, "-X", "query should pass -X")
  end)
end)

test("pg ping: passes -X to skip .psqlrc", function()
  with_executable(function()
    local args = capture_system_args("", function()
      pg.ping("postgresql://localhost/db")
    end)
    has_arg(args, "-X", "ping should pass -X")
  end)
end)

-- ── PostgreSQL routines ─────────────────────────────────────────────────

test("pg list_routines: queries pg_proc and parses functions/procedures", function()
  with_executable(function()
    local csv = table.concat({
      "source_id,schema,name,identity_arguments,kind",
      "12345,public,user_display_name,user_id integer,function",
      "23456,admin,audit_touch,,procedure",
      "",
    }, "\n")
    local args = capture_system_args(csv, function()
      local routines, err = pg.list_routines("postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(#routines, 2, "routine count")
      eq(routines[1].name, "user_display_name", "public routine name is bare")
      eq(routines[1].display, "user_display_name(user_id integer)", "function display")
      eq(routines[1].type, "function", "function type")
      eq(routines[1].source_id, "12345", "function source id")
      eq(routines[2].name, "admin.audit_touch", "non-public routine is schema-qualified")
      eq(routines[2].display, "admin.audit_touch()", "procedure display")
      eq(routines[2].type, "procedure", "procedure type")
    end)
    local sql_arg = last_arg(args)
    contains(sql_arg, "pg_proc", "routine list queries pg_proc")
    contains(sql_arg, "pg_namespace", "routine list queries schemas")
  end)
end)

test("pg get_routine_source: can select exact routine by oid source id", function()
  with_executable(function()
    local csv = "source\n\"CREATE OR REPLACE FUNCTION overloaded(value text)\nRETURNS text\nLANGUAGE sql\nAS $$ SELECT value; $$\"\n"
    local source, err
    local args = capture_system_args(csv, function()
      source, err = pg.get_routine_source("98765", "postgresql://localhost/db")
    end)
    assert(not err, "should not error: " .. tostring(err))
    contains(source, "overloaded(value text)", "source contains selected overload")
    local sql_arg = last_arg(args)
    contains(sql_arg, "p.oid = 98765::oid", "source query filters by oid")
  end)
end)

test("pg get_routine_source: uses pg_get_functiondef and preserves source text", function()
  with_executable(function()
    local csv = "source\n\"CREATE OR REPLACE FUNCTION user_display_name(user_id integer)\nRETURNS text\nLANGUAGE sql\nAS $$ SELECT 'user'; $$\"\n"
    local source, err
    local args = capture_system_args(csv, function()
      source, err = pg.get_routine_source("user_display_name", "postgresql://localhost/db")
    end)
    assert(not err, "should not error: " .. tostring(err))
    contains(source, "CREATE OR REPLACE FUNCTION", "source contains function DDL")
    contains(source, "RETURNS text", "source preserves multiline body")
    local sql_arg = last_arg(args)
    contains(sql_arg, "pg_get_functiondef", "source query uses pg_get_functiondef")
    contains(sql_arg, "user_display_name", "source query filters by routine")
  end)
end)

test("pg list_routines: strips bare IN mode from procedure arguments", function()
  with_executable(function()
    local csv = table.concat({
      "source_id,schema,name,identity_arguments,kind",
      '23456,public,mark_order_status,"IN order_id integer, IN new_status text",procedure',
      '34567,public,swap_vals,"INOUT a integer, INOUT b integer",procedure',
      "",
    }, "\n")
    capture_system_args(csv, function()
      local routines, err = pg.list_routines("postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(routines[1].display, "mark_order_status(order_id integer, new_status text)",
        "IN mode stripped for display parity with functions")
      eq(routines[1].arguments, "order_id integer, new_status text", "arguments field cleaned")
      eq(routines[2].display, "swap_vals(INOUT a integer, INOUT b integer)",
        "INOUT mode is meaningful and kept")
    end)
  end)
end)

-- ── PostgreSQL EXPLAIN safety ────────────────────────────────────────────
-- ANALYZE executes the statement; it must only be added for read-only SQL.

test("pg explain: SELECT uses ANALYZE for actual timings", function()
  with_executable(function()
    local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
      pg.explain("SELECT * FROM users", "postgresql://localhost/db")
    end)
    contains(last_arg(args), "EXPLAIN (FORMAT TEXT, ANALYZE) SELECT", "SELECT gets ANALYZE")
  end)
end)

test("pg explain: UPDATE/DELETE/INSERT never use ANALYZE (would execute the DML)", function()
  with_executable(function()
    for _, stmt in ipairs({
      "UPDATE users SET age = 1 WHERE id = 1",
      "DELETE FROM users WHERE id = 1",
      "INSERT INTO users (name) VALUES ('x')",
    }) do
      local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
        pg.explain(stmt, "postgresql://localhost/db")
      end)
      local sql_arg = last_arg(args)
      assert(not sql_arg:find("ANALYZE", 1, true),
        "no ANALYZE for: " .. stmt .. " (got: " .. sql_arg .. ")")
      contains(sql_arg, "EXPLAIN (FORMAT TEXT) ", "plain EXPLAIN used")
    end
  end)
end)

test("pg explain: WITH gets plain EXPLAIN (may contain data-modifying CTEs)", function()
  with_executable(function()
    local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
      pg.explain("WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone",
        "postgresql://localhost/db")
    end)
    assert(not last_arg(args):find("ANALYZE", 1, true), "no ANALYZE for WITH")
  end)
end)

-- ── SQLite .sqliterc bypass ─────────────────────────────────────────────

test("sqlite query: passes -init '' to skip .sqliterc", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      sqlite.query("SELECT 1", "sqlite:test.db")
    end)
    has_arg(args, "-init", "query should pass -init")
  end)
end)

-- ── SQL Server adapter ───────────────────────────────────────────────────

test("adapter registry resolves sqlserver and mssql URLs", function()
  local a1, err1 = adapters.resolve("sqlserver://sa:pw@localhost:1433/grip_test")
  assert(a1 == sqlserver, "sqlserver adapter mismatch: " .. tostring(err1))
  local a2, err2 = adapters.resolve("mssql://sa:pw@localhost/grip_test")
  assert(a2 == sqlserver, "mssql adapter mismatch: " .. tostring(err2))
end)

test("sqlserver parse_url: full URL parses all fields", function()
  local r = sqlserver._parse_url("sqlserver://sa:secret@db.host:14330/grip_test")
  eq(r.user, "sa", "user")
  eq(r.pass, "secret", "pass")
  eq(r.host, "db.host", "host")
  eq(r.port, "14330", "port")
  eq(r.dbname, "grip_test", "dbname")
end)

test("sqlserver query: parses sqlcmd tab output", function()
  with_executable(function()
    local out = table.concat({
      "id\tname",
      "--\t----",
      "1\tAlice",
      "2\tNULL",
      "",
      "(2 rows affected)",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.query("SELECT id, name FROM users", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.columns[1], "id", "first column")
      eq(result.columns[2], "name", "second column")
      eq(result.rows[1][2], "Alice", "first row value")
      eq(result.rows[2][2], "", "NULL becomes empty string")
    end)
  end)
end)

test("sqlserver query: builds sqlcmd args for non-interactive use", function()
  with_executable(function()
    local args = capture_system_args("id\n--\n1\n", function()
      sqlserver.query("SELECT 1", "sqlserver://sa:pw@localhost:1433/grip_test")
    end)
    has_arg(args, "sqlcmd", "uses sqlcmd")
    has_arg(args, "-S", "sets server")
    has_arg(args, "-d", "sets database")
    has_arg(args, "-U", "sets user")
    has_arg(args, "-P", "sets password")
    has_arg(args, "-Q", "sets query")
  end)
end)

test("sqlserver list_tables: parses table and view rows", function()
  with_executable(function()
    local out = table.concat({
      "table_name\ttable_type",
      "----------\t----------",
      "users\ttable",
      "no_pk_view\tview",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.list_tables("sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(#result, 2, "two objects")
      eq(result[1].name, "users", "table name")
      eq(result[1].type, "table", "table type")
      eq(result[2].type, "view", "view type")
    end)
  end)
end)

test("sqlserver execute: parses affected rows from (N rows affected)", function()
  with_executable(function()
    with_system_mock("\n(3 rows affected)\n", "", 0, function()
      local result, err = sqlserver.execute("UPDATE users SET x=1", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
    end)
  end)
end)

test("sqlserver execute: does not send SET NOCOUNT ON (would suppress the row count)", function()
  with_executable(function()
    local args = capture_system_args("\n(1 rows affected)\n", function()
      sqlserver.execute("UPDATE users SET x=1", "sqlserver://sa:pw@localhost/grip_test")
    end)
    local sql_arg = last_arg(args)
    assert(not sql_arg:find("NOCOUNT", 1, true), "execute must not set NOCOUNT: " .. sql_arg)
  end)
end)

test("sqlserver query: still sends SET NOCOUNT ON (keeps row count out of the grid)", function()
  with_executable(function()
    local args = capture_system_args("id\n--\n1\n", function()
      sqlserver.query("SELECT 1", "sqlserver://sa:pw@localhost:1433/grip_test")
    end)
    contains(last_arg(args), "SET NOCOUNT ON", "query must still set NOCOUNT")
  end)
end)

test("sqlserver get_primary_keys: parses key columns", function()
  with_executable(function()
    local out = table.concat({
      "column_name",
      "-----------",
      "tenant_id",
      "user_id",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.get_primary_keys("composite_pk", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(#result, 2, "two primary key columns")
      eq(result[1], "tenant_id", "first pk")
      eq(result[2], "user_id", "second pk")
    end)
  end)
end)

-- ── MySQL DEFAULT VALUES rewriting ───────────────────────────────────────────

test("mysql execute: DEFAULT VALUES is rewritten", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("INSERT INTO t DEFAULT VALUES", "mysql://root@localhost/test")
    vim.system = orig
    local sql_arg = captured_args[#captured_args]
    contains(sql_arg, "() VALUES ()", "DEFAULT VALUES rewrite")
    assert(not sql_arg:find("DEFAULT VALUES", 1, true), "DEFAULT VALUES should be gone")
  end)
end)

test("mysql execute: non-DEFAULT-VALUES SQL unchanged", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("INSERT INTO t (name) VALUES ('x')", "mysql://root@localhost/test")
    vim.system = orig
    local sql_arg = captured_args[#captured_args]
    contains(sql_arg, "VALUES ('x')", "SQL unchanged")
  end)
end)

test("mysql execute: affected row parsing from stderr", function()
  with_executable(function()
    with_system_mock("", "3 rows affected", 0, function()
      local result, err = mysql.execute("UPDATE t SET x=1", "mysql://root@localhost/test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
    end)
  end)
end)

test("mysql execute: 0 rows affected", function()
  with_executable(function()
    with_system_mock("", "0 rows affected", 0, function()
      local result = mysql.execute("UPDATE t SET x=1 WHERE 1=0", "mysql://root@localhost/test")
      eq(result.affected, 0, "affected")
    end)
  end)
end)

-- ── SQLite PRAGMA quoting ────────────────────────────────────────────────────

test("sqlite get_primary_keys: table name is quoted in PRAGMA", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    sqlite.get_primary_keys("users", "sqlite:test.db")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    contains(sql_arg, '"users"', "table name should be quoted")
  end)
end)

test("sqlite get_primary_keys: embedded quote is escaped", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    sqlite.get_primary_keys('my"table', "sqlite:test.db")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    -- Double-quote escaping: my"table becomes my""table inside quotes
    contains(sql_arg, 'my""table', "embedded quote should be doubled")
  end)
end)

-- ── DuckDB httpfs extension loading ─────────────────────────────────────────

test("duckdb query: SQL with HTTP URL prepends INSTALL/LOAD httpfs", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      duckdb.query("SELECT * FROM 'https://example.com/data.csv'", "duckdb::memory:")
    end)
    local sql_arg = args[#args]
    contains(sql_arg, "INSTALL httpfs", "should prepend INSTALL httpfs")
    contains(sql_arg, "LOAD httpfs", "should prepend LOAD httpfs")
    contains(sql_arg, "https://example.com/data.csv", "original SQL preserved")
  end)
end)

test("duckdb query: SQL without HTTP URL does not prepend httpfs", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      duckdb.query("SELECT * FROM users", "duckdb::memory:")
    end)
    local sql_arg = args[#args]
    assert(not sql_arg:find("httpfs", 1, true), "should not contain httpfs: " .. sql_arg)
  end)
end)

test("duckdb query: httpfs timeout is at least 30 seconds", function()
  with_executable(function()
    local captured_opts
    local orig = vim.system
    vim.system = function(a, opts, cb)
      captured_opts = opts
      local r = { stdout = "col\nval\n", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.query("SELECT * FROM 'https://example.com/data.csv'", "duckdb::memory:")
    vim.system = orig
    assert(captured_opts.timeout >= 30000, "timeout should be >= 30000, got " .. tostring(captured_opts.timeout))
  end)
end)

test("duckdb query: http URL also triggers httpfs", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      duckdb.query("SELECT * FROM 'http://example.com/data.csv'", "duckdb::memory:")
    end)
    local sql_arg = args[#args]
    contains(sql_arg, "httpfs", "http should also trigger httpfs")
  end)
end)

-- ── SQLite get_constraints ───────────────────────────────────────────────────

test("sqlite get_constraints: queries sqlite_master with table name", function()
  local captured_args
  local orig = vim.system
  vim.system = function(a, _o, cb)
    captured_args = a
    local r = { stdout = "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  sqlite.get_constraints("users", "sqlite:test.db")
  vim.system = orig
  local sql_arg = last_arg(captured_args)
  contains(sql_arg, "sqlite_master", "queries sqlite_master")
  contains(sql_arg, "users", "filters by table name")
end)

test("sqlite get_constraints: parses UNIQUE constraint from DDL", function()
  local ddl = "sql\nCREATE TABLE users (\n  id INTEGER,\n  email TEXT,\n  UNIQUE (email)\n)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("users", "sqlite:test.db")
    local found_unique = false
    for _, c in ipairs(result) do
      if c.type == "UNIQUE" then found_unique = true end
    end
    assert(found_unique, "should detect UNIQUE constraint in DDL")
  end)
end)

test("sqlite get_constraints: parses CHECK constraint from DDL", function()
  local ddl = "sql\nCREATE TABLE users (\n  id INTEGER,\n  age INTEGER,\n  CHECK (age > 0)\n)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("users", "sqlite:test.db")
    local found_check = false
    for _, c in ipairs(result) do
      if c.type == "CHECK" then found_check = true end
    end
    assert(found_check, "should detect CHECK constraint in DDL")
  end)
end)

test("sqlite get_constraints: falls back to DDL entry when no named constraints", function()
  local ddl = "sql\nCREATE TABLE simple (id INTEGER, name TEXT)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("simple", "sqlite:test.db")
    eq(#result, 1, "one fallback entry")
    eq(result[1].type, "DDL", "fallback type is DDL")
    contains(result[1].definition, "CREATE TABLE", "definition contains DDL")
  end)
end)

test("sqlite get_constraints: returns empty for empty DDL output", function()
  with_system_mock("", "", 0, function()
    local result = sqlite.get_constraints("empty", "sqlite:test.db")
    eq(#result, 0, "empty list for empty output")
  end)
end)

-- ── DuckDB get_constraints ───────────────────────────────────────────────────

test("duckdb get_constraints: queries duckdb_constraints() for table", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.get_constraints("users", "duckdb::memory:")
    vim.system = orig
    local sql_arg = captured_args[#captured_args]
    contains(sql_arg, "duckdb_constraints", "queries duckdb_constraints()")
    contains(sql_arg, "users", "filters by table name")
  end)
end)

test("duckdb get_constraints: filters by schema name", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.get_constraints("myschema.users", "duckdb:test.db")
    vim.system = orig
    local sql_arg = captured_args[#captured_args]
    contains(sql_arg, "myschema", "includes schema filter")
    contains(sql_arg, "users", "includes table filter")
  end)
end)

test("duckdb get_constraints: parses CSV output into constraint rows", function()
  with_executable(function()
    local csv = "constraint_name,constraint_type,definition\nemail_unique,UNIQUE,email\nage_check,CHECK,age > 0\n"
    with_system_mock(csv, "", 0, function()
      local result = duckdb.get_constraints("users", "duckdb::memory:")
      eq(#result, 2, "two constraints parsed")
      eq(result[1].name, "email_unique", "first constraint name")
      eq(result[1].type, "UNIQUE", "first constraint type")
      eq(result[2].name, "age_check", "second constraint name")
      eq(result[2].type, "CHECK", "second constraint type")
    end)
  end)
end)

test("duckdb get_constraints: returns empty list on query failure", function()
  with_executable(function()
    with_system_mock("", "Error: table not found", 1, function()
      local result, err = duckdb.get_constraints("missing", "duckdb::memory:")
      eq(#result, 0, "empty list on error")
      -- error is returned (or nil: either is acceptable since duckdb silences errors)
    end)
  end)
end)

-- ── MySQL sql_mode: NO_BACKSLASH_ESCAPES ─────────────────────────────────────

test("mysql query: --init-command includes NO_BACKSLASH_ESCAPES", function()
  with_executable(function()
    local args = capture_system_args("id\n1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    local init_cmd = nil
    for _, v in ipairs(args) do
      if type(v) == "string" and v:find("--init-command", 1, true) then
        init_cmd = v; break
      end
    end
    assert(init_cmd ~= nil, "must have --init-command arg")
    contains(init_cmd, "NO_BACKSLASH_ESCAPES", "query sql_mode must include NO_BACKSLASH_ESCAPES")
  end)
end)

test("mysql execute: --init-command includes NO_BACKSLASH_ESCAPES", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("UPDATE t SET x=1 WHERE id=1", "mysql://root@localhost/test")
    vim.system = orig
    local init_cmd = nil
    for _, v in ipairs(captured_args) do
      if type(v) == "string" and v:find("--init-command", 1, true) then
        init_cmd = v; break
      end
    end
    assert(init_cmd ~= nil, "must have --init-command arg")
    contains(init_cmd, "NO_BACKSLASH_ESCAPES", "execute sql_mode must include NO_BACKSLASH_ESCAPES")
  end)
end)

-- ── MySQL query flags ────────────────────────────────────────────────────────
-- MySQL and MariaDB are driven identically: --batch for both.

test("mysql query: uses --batch flag", function()
  with_executable(function()
    local args = capture_system_args("id\t1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    has_arg(args, "--batch", "MySQL should use --batch")
  end)
end)

-- ── PostgreSQL get_schema_batch ──────────────────────────────────────────────
-- get_schema_batch returns all table columns in a single query instead of N+1.
-- Contract: { [table_name] = [{column_name, data_type, is_nullable}] } or nil.

test("pg get_schema_batch: returns columns keyed by table name", function()
  -- CSV output: psql --csv returns header + rows for all tables in one query
  local csv_stdout = table.concat({
    "table_schema,table_name,column_name,data_type,is_nullable",
    "public,users,id,integer,NO",
    "public,users,email,text,NO",
    "public,users,name,text,YES",
    "public,orders,id,integer,NO",
    "public,orders,user_id,integer,NO",
    "public,orders,total,numeric,YES",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = pg.get_schema_batch("postgresql://localhost/test")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "must have users key")
  assert(result["orders"] ~= nil, "must have orders key")
  eq(#result["users"], 3, "users has 3 columns")
  eq(#result["orders"], 3, "orders has 3 columns")
  eq(result["users"][1].column_name, "id", "users first col is id")
  eq(result["users"][2].column_name, "email", "users second col is email")
  eq(result["orders"][3].data_type, "numeric", "orders third col type is numeric")
end)

test("pg get_schema_batch: non-public schema uses schema.table key", function()
  local csv_stdout = table.concat({
    "table_schema,table_name,column_name,data_type,is_nullable",
    "analytics,events,id,bigint,NO",
    "analytics,events,ts,timestamp,NO",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = pg.get_schema_batch("postgresql://localhost/test")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["analytics.events"] ~= nil, "must have analytics.events key")
  eq(#result["analytics.events"], 2, "analytics.events has 2 columns")
end)

test("pg get_schema_batch: mixed schemas", function()
  local csv_stdout = table.concat({
    "table_schema,table_name,column_name,data_type,is_nullable",
    "public,users,id,integer,NO",
    "analytics,events,id,bigint,NO",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = pg.get_schema_batch("postgresql://localhost/test")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "public.users -> users")
  assert(result["analytics.events"] ~= nil, "analytics.events keeps prefix")
end)

test("pg get_schema_batch: psql failure returns nil", function()
  local result
  with_system_mock("", "connection refused", 1, function()
    result = pg.get_schema_batch("postgresql://localhost/test")
  end)
  eq(result, nil, "should return nil on failure")
end)

test("pg get_schema_batch: single subprocess call", function()
  local call_count = 0
  local orig = vim.system
  vim.system = function(args, opts, cb)
    call_count = call_count + 1
    local csv = "table_schema,table_name,column_name,data_type,is_nullable\npublic,t1,c1,int,NO\n"
    local r = { stdout = csv, stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  pg.get_schema_batch("postgresql://localhost/test")
  vim.system = orig
  eq(call_count, 1, "exactly one subprocess call for batch")
end)

-- ── MySQL get_schema_batch ──────────────────────────────────────────────────

test("mysql get_schema_batch: returns columns keyed by table name", function()
  -- MySQL --batch output format (tab-separated)
  local tsv_stdout = table.concat({
    "table_name\tcolumn_name\tdata_type\tis_nullable",
    "customers\tcust_id\tint\tNO",
    "customers\tregion\tvarchar(255)\tYES",
    "products\tsku\tvarchar(50)\tNO",
    "products\tprice\tdecimal(10,2)\tYES",
  }, "\n") .. "\n"

  local result
  with_executable(function()
    with_system_mock(tsv_stdout, "", 0, function()
      result = mysql.get_schema_batch("mysql://root:pass@localhost/testdb")
    end)
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["customers"] ~= nil, "must have customers key")
  assert(result["products"] ~= nil, "must have products key")
  eq(#result["customers"], 2, "customers has 2 columns")
  eq(#result["products"], 2, "products has 2 columns")
  eq(result["customers"][1].column_name, "cust_id", "first col name")
  eq(result["products"][2].data_type, "decimal(10,2)", "price data type")
end)

test("mysql get_schema_batch: mysql failure returns nil", function()
  local result
  with_executable(function()
    with_system_mock("", "access denied", 1, function()
      result = mysql.get_schema_batch("mysql://root:pass@localhost/testdb")
    end)
  end)
  eq(result, nil, "should return nil on failure")
end)

test("mysql get_schema_batch: single subprocess call", function()
  local call_count = 0
  local orig = vim.system
  local orig_exe = vim.fn.executable
  vim.fn.executable = function() return 1 end
  vim.system = function(args, opts, cb)
    call_count = call_count + 1
    local csv = "table_name\tcolumn_name\tdata_type\tis_nullable\nt1\tc1\tint\tNO\n"
    local r = { stdout = csv, stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  mysql.get_schema_batch("mysql://root:pass@localhost/testdb")
  vim.system = orig
  vim.fn.executable = orig_exe
  eq(call_count, 1, "exactly one subprocess call for batch")
end)

-- ── SQLite get_schema_batch ──────────────────────────────────────────────────

test("sqlite get_schema_batch: returns columns keyed by table name", function()
  local csv_stdout = table.concat({
    "table_name,column_name,data_type,is_nullable",
    "orders,id,INTEGER,YES",
    "orders,total,REAL,YES",
    "users,id,INTEGER,YES",
    "users,name,TEXT,NO",
    "users,email,TEXT,YES",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = sqlite.get_schema_batch("sqlite:test.db")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "must have users key")
  assert(result["orders"] ~= nil, "must have orders key")
  eq(#result["users"], 3, "users has 3 columns")
  eq(#result["orders"], 2, "orders has 2 columns")
  eq(result["users"][2].column_name, "name", "users second col is name")
  eq(result["users"][2].is_nullable, "NO", "name is NOT NULL")
end)

test("sqlite get_schema_batch: failure returns nil", function()
  local result
  with_system_mock("", "unable to open database", 1, function()
    result = sqlite.get_schema_batch("sqlite:nonexistent.db")
  end)
  eq(result, nil, "should return nil on failure")
end)

-- ── SQLite get_indexes ───────────────────────────────────────────────────────
-- Single pragma_index_list/pragma_index_info join (one spawn) replaces the old
-- index_list-then-loop-over-index_info (one spawn per index).

test("sqlite get_indexes: groups columns per index preserving seqno order", function()
  local csv_stdout = table.concat({
    "idx_name,unique,origin,seqno,col_name",
    "idx_desc,0,c,0,d",
    "idx_desc,0,c,1,a",
    "idx_ab,1,c,0,a",
    "idx_ab,1,c,1,b",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = sqlite.get_indexes("t", "sqlite:test.db")
  end)

  eq(#result, 2, "two indexes")
  eq(result[1].name, "idx_desc", "first index in seq order")
  eq(result[1].type, "INDEX", "plain index")
  eq(#result[1].columns, 2, "idx_desc has 2 columns")
  eq(result[1].columns[1], "d", "idx_desc column order follows seqno")
  eq(result[1].columns[2], "a", "idx_desc column order follows seqno")
  eq(result[2].name, "idx_ab", "second index in seq order")
  eq(result[2].type, "UNIQUE", "unique index")
  eq(result[2].columns[1], "a", "idx_ab column order follows seqno")
  eq(result[2].columns[2], "b", "idx_ab column order follows seqno")
end)

test("sqlite get_indexes: origin=pk maps to PRIMARY", function()
  local csv_stdout = table.concat({
    "idx_name,unique,origin,seqno,col_name",
    "sqlite_autoindex_t_1,1,pk,0,tenant_id",
    "sqlite_autoindex_t_1,1,pk,1,user_id",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = sqlite.get_indexes("t", "sqlite:test.db")
  end)

  eq(#result, 1, "one index")
  eq(result[1].type, "PRIMARY", "pk origin maps to PRIMARY")
  eq(#result[1].columns, 2, "composite pk has 2 columns")
end)

test("sqlite get_indexes: single spawn regardless of index count", function()
  local csv_stdout = table.concat({
    "idx_name,unique,origin,seqno,col_name",
    "idx_a,0,c,0,x",
    "idx_b,0,c,0,y",
    "idx_c,1,c,0,z",
  }, "\n") .. "\n"

  local calls = 0
  local orig = vim.system
  vim.system = function(_args, _opts, cb)
    calls = calls + 1
    local r = { stdout = csv_stdout, stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local result = sqlite.get_indexes("t", "sqlite:test.db")
  vim.system = orig

  eq(#result, 3, "three indexes")
  eq(calls, 1, "exactly one process spawned for any number of indexes")
end)

test("sqlite get_indexes: table name is escaped as a string literal, not an identifier", function()
  local args = capture_system_args("idx_name,unique,origin,seqno,col_name\n", function()
    sqlite.get_indexes("o'brien", "sqlite:test.db")
  end)
  local sql_arg = last_arg(args)
  contains(sql_arg, "pragma_index_list('o''brien')", "single quote doubled via escape_literal")
end)

test("sqlite get_indexes: empty result for table with no indexes", function()
  local result
  with_system_mock("idx_name,unique,origin,seqno,col_name\n", "", 0, function()
    result = sqlite.get_indexes("t", "sqlite:test.db")
  end)
  eq(#result, 0, "no indexes")
end)

-- ── DuckDB get_schema_batch ───────────────────────────────────────────────────
-- Unlike pg/mysql/sqlite, DuckDB's batch query is always the same 8-column shape
-- (rtype, database_name, schema_name, table_name, column_name, data_type,
-- is_nullable, column_index), sourced from duckdb_columns()/duckdb_views() in both
-- attachment modes -- so is_nullable/column-order is tested in both modes, plus the
-- generated SQL text itself is checked directly (execution correctness can't be
-- verified here -- no duckdb binary in this sandbox).

test("duckdb get_schema_batch: no attachments, is_nullable comes from duckdb_columns()", function()
  local csv_stdout = table.concat({
    "rtype,database_name,schema_name,table_name,column_name,data_type,is_nullable,column_index",
    "col,plain,main,users,id,INTEGER,NO,0",
    "col,plain,main,users,name,VARCHAR,YES,1",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = duckdb.get_schema_batch("duckdb:plain.db")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "must have users key")
  eq(result["users"][1].column_name, "id", "column order preserved (id first)")
  eq(result["users"][1].is_nullable, "NO", "id is NOT NULL")
  eq(result["users"][2].column_name, "name", "column order preserved (name second)")
  eq(result["users"][2].is_nullable, "YES", "name is nullable")
end)

test("duckdb get_schema_batch: with attachments, is_nullable kept for main catalog, blanked for attached", function()
  local url = "duckdb:test_attach.db"

  -- Fake a successful ATTACH so _attachments[url] is populated (drives has_attachments=true).
  with_system_mock("", "", 0, function()
    duckdb.load_attachments(url, { { dsn = "sqlite:other.db", alias = "sup" } })
  end)

  -- database_name "test_attach" matches _extract_path("test_attach.db") -> main_catalog "test_attach".
  local csv_stdout = table.concat({
    "rtype,database_name,schema_name,table_name,column_name,data_type,is_nullable,column_index",
    "col,test_attach,main,users,id,INTEGER,NO,0",
    "col,test_attach,main,users,name,VARCHAR,YES,1",
    "col,sup,main,orders,id,INTEGER,YES,0",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = duckdb.get_schema_batch(url)
  end)

  duckdb.load_attachments(url, {})  -- reset attachment state for later tests

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "main-catalog table present")
  eq(result["users"][1].is_nullable, "NO", "main catalog is_nullable preserved")
  eq(result["users"][2].is_nullable, "YES", "main catalog is_nullable preserved (2nd col)")
  assert(result["sup.orders"] ~= nil, "attached-catalog table present")
  eq(result["sup.orders"][1].is_nullable, "",
    "attached catalog is_nullable blanked -- matches get_column_info's attached-catalog branch")
end)

test("duckdb get_schema_batch: parser preserves whatever row order the query returns", function()
  -- Regression guard: the Lua parser must not silently reorder rows -- column
  -- order in the prompt depends entirely on _make_schema_batch_sql's ORDER BY
  -- (checked directly below), not on any re-sorting here.
  local csv_stdout = table.concat({
    "rtype,database_name,schema_name,table_name,column_name,data_type,is_nullable,column_index",
    "col,plain,main,users,name,VARCHAR,YES,1",
    "col,plain,main,users,id,INTEGER,NO,0",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = duckdb.get_schema_batch("duckdb:plain.db")
  end)

  eq(result["users"][1].column_name, "name", "parser preserves row order as received")
  eq(result["users"][2].column_name, "id", "parser preserves row order as received")
end)

test("duckdb _make_schema_batch_sql: orders by table_name + column_index so column order is stable", function()
  -- Was previously "ORDER BY 1, 2, 3" (rtype, database_name, schema_name only) --
  -- no guarantee at all for column order within a table, or even that a table's
  -- rows stay grouped together.
  local sql_no_att = duckdb._make_schema_batch_sql(false, "plain")
  contains(sql_no_att, "column_index", "SELECT list includes column_index")
  contains(sql_no_att, "ORDER BY 2, 3, 4, 8", "ORDER BY includes table_name + column_index")

  local sql_att = duckdb._make_schema_batch_sql(true, "plain")
  contains(sql_att, "column_index", "SELECT list includes column_index (attachments)")
  contains(sql_att, "ORDER BY 2, 3, 4, 8", "ORDER BY includes table_name + column_index (attachments)")
end)

test("duckdb _make_schema_batch_sql: is_nullable sourced from duckdb_columns(), not information_schema", function()
  -- get_column_info never reads information_schema for DuckDB (both its branches use
  -- duckdb_columns()); the batch query previously did for the no-attachments case,
  -- which meant its is_nullable format was an unverified guess rather than proven-correct.
  local sql_no_att = duckdb._make_schema_batch_sql(false, "plain")
  assert(not sql_no_att:find("information_schema", 1, true),
    "no-attachments batch query must not depend on information_schema's is_nullable convention")
  contains(sql_no_att, "duckdb_columns()", "sourced from duckdb_columns()")
  contains(sql_no_att, "duckdb_views()", "views still registered name-only via duckdb_views()")
end)

-- ── Completion: get_schema prefers batch over per-table ─────────────────────
-- When get_schema_batch returns data, list_tables + get_column_info must NOT be called.

test("completion get_schema: uses batch when available, skips per-table", function()
  local compl = require("dadbod-grip.completion")
  local db_mod = require("dadbod-grip.db")

  local batch_called = false
  local list_called = false
  local col_called = false

  local orig_batch = db_mod.get_schema_batch
  local orig_list = db_mod.list_tables
  local orig_cols = db_mod.get_column_info

  db_mod.get_schema_batch = function(url)
    batch_called = true
    return {
      ["users"] = {
        { column_name = "id", data_type = "integer", is_nullable = "NO" },
      },
    }
  end
  db_mod.list_tables = function(url)
    list_called = true
    return { { name = "users" } }, nil
  end
  db_mod.get_column_info = function(tn, url)
    col_called = true
    return {}, nil
  end

  compl.invalidate("postgresql://localhost/batch_pref_test")
  compl.get_schema("postgresql://localhost/batch_pref_test")

  db_mod.get_schema_batch = orig_batch
  db_mod.list_tables = orig_list
  db_mod.get_column_info = orig_cols

  assert(batch_called, "get_schema_batch must be called")
  assert(not list_called, "list_tables must NOT be called when batch succeeds")
  assert(not col_called, "get_column_info must NOT be called when batch succeeds")
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nadapter_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
