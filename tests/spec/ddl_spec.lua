-- ddl_spec.lua: unit tests for DDL module scoping, SQL generation, quoting
local ddl = require("dadbod-grip.ddl")
local sql = require("dadbod-grip.sql")

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

local function not_contains(s, pattern, msg)
  assert(not s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' NOT to contain '" .. pattern .. "'")
end

-- ── module scoping ───────────────────────────────────────────────────────────

test("ddl: build_create_sql is not a global", function()
  eq(rawget(_G, "build_create_sql"), nil, "_G.build_create_sql")
end)

test("ddl: build_create_sql is not a public export", function()
  eq(ddl.build_create_sql, nil, "ddl.build_create_sql")
end)

-- ── build_create_sql: SQL generation ─────────────────────────────────────────

-- _build_create_sql takes (table_name, columns, url, on_done) but we only
-- care about the SQL it generates. We mock confirm_ddl and db.execute via
-- capturing the SQL string that would be passed to confirm_ddl.
-- Since _build_create_sql calls confirm_ddl (which opens a float), we cannot
-- call it directly without a UI. Instead, we test the SQL generation logic
-- by reproducing it here using the same sql.lua functions the module uses.

local function make_create_sql(table_name, columns)
  local col_defs = {}
  local pk_cols = {}
  for _, col in ipairs(columns) do
    local def = sql.quote_ident(col.name) .. " " .. col.type
    table.insert(col_defs, def)
    if col.pk then
      table.insert(pk_cols, sql.quote_ident(col.name))
    end
  end
  if #pk_cols > 0 then
    table.insert(col_defs, "PRIMARY KEY (" .. table.concat(pk_cols, ", ") .. ")")
  end
  return string.format(
    "CREATE TABLE %s (\n  %s\n)",
    sql.quote_ident(table_name),
    table.concat(col_defs, ",\n  ")
  )
end

test("create SQL: single column with PK", function()
  local result = make_create_sql("users", {{ name = "id", type = "integer", pk = true }})
  contains(result, 'CREATE TABLE "users"', "table name")
  contains(result, '"id" integer', "column def")
  contains(result, 'PRIMARY KEY ("id")', "PK clause")
end)

test("create SQL: multiple columns, first PK", function()
  local result = make_create_sql("users", {
    { name = "id", type = "integer", pk = true },
    { name = "name", type = "text", pk = false },
  })
  contains(result, '"id" integer', "first col")
  contains(result, '"name" text', "second col")
  contains(result, 'PRIMARY KEY ("id")', "PK")
end)

test("create SQL: composite PK", function()
  local result = make_create_sql("join_table", {
    { name = "a_id", type = "integer", pk = true },
    { name = "b_id", type = "integer", pk = true },
  })
  contains(result, 'PRIMARY KEY ("a_id", "b_id")', "composite PK")
end)

test("create SQL: no PK columns", function()
  local result = make_create_sql("logs", {
    { name = "msg", type = "text", pk = false },
  })
  not_contains(result, "PRIMARY KEY", "no PK clause")
end)

test("create SQL: table name is double-quoted", function()
  local result = make_create_sql("my table", {{ name = "id", type = "int", pk = false }})
  contains(result, '"my table"', "quoted table name")
end)

test("create SQL: column name with spaces is quoted", function()
  local result = make_create_sql("t", {{ name = "my col", type = "text", pk = false }})
  contains(result, '"my col"', "quoted column name")
end)

test("create SQL: column type preserved verbatim", function()
  local result = make_create_sql("t", {{ name = "x", type = "varchar(255)", pk = false }})
  contains(result, "varchar(255)", "type verbatim")
end)

test("create SQL: empty columns produces valid SQL", function()
  local result = make_create_sql("empty", {})
  contains(result, 'CREATE TABLE "empty"', "table name")
end)

-- ── DDL SQL patterns: rename ─────────────────────────────────────────────────

test("rename SQL: correct ALTER TABLE format", function()
  local ddl_sql = string.format(
    'ALTER TABLE %s RENAME COLUMN %s TO %s',
    sql.quote_ident("users"),
    sql.quote_ident("old_col"),
    sql.quote_ident("new_col")
  )
  contains(ddl_sql, 'ALTER TABLE "users"', "table")
  contains(ddl_sql, 'RENAME COLUMN "old_col" TO "new_col"', "rename")
end)

test("rename SQL: names are quoted for injection safety", function()
  local ddl_sql = string.format(
    'ALTER TABLE %s RENAME COLUMN %s TO %s',
    sql.quote_ident('my"table'),
    sql.quote_ident("col; DROP"),
    sql.quote_ident("safe_name")
  )
  -- quote_ident doubles internal quotes
  contains(ddl_sql, '"my""table"', "escaped table name")
  contains(ddl_sql, '"col; DROP"', "column name is quoted not executed")
end)

-- ── DDL SQL patterns: drop column ────────────────────────────────────────────

test("drop column SQL: correct format", function()
  local ddl_sql = string.format(
    'ALTER TABLE %s DROP COLUMN %s',
    sql.quote_ident("users"),
    sql.quote_ident("email")
  )
  contains(ddl_sql, 'ALTER TABLE "users" DROP COLUMN "email"', "drop column")
end)

test("drop column SQL: column name is quoted", function()
  local ddl_sql = string.format(
    'ALTER TABLE %s DROP COLUMN %s',
    sql.quote_ident("t"),
    sql.quote_ident("my col")
  )
  contains(ddl_sql, '"my col"', "quoted col name")
end)

-- ── DDL SQL patterns: drop table ─────────────────────────────────────────────

test("drop table SQL: correct format", function()
  local ddl_sql = "DROP TABLE " .. sql.quote_ident("users")
  eq(ddl_sql, 'DROP TABLE "users"', "drop table")
end)

test("drop table SQL: table name is quoted", function()
  local ddl_sql = "DROP TABLE " .. sql.quote_ident("my table")
  contains(ddl_sql, '"my table"', "quoted name")
end)

-- ── drop table SQL: CASCADE scoping (M._build_drop_sql) ──────────────────────

test("drop table CASCADE: postgresql appends CASCADE when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "postgresql", true)
  eq(ddl_sql, 'DROP TABLE "users" CASCADE', "postgresql + referenced")
end)

test("drop table CASCADE: duckdb appends CASCADE when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "duckdb", true)
  eq(ddl_sql, 'DROP TABLE "users" CASCADE', "duckdb + referenced")
end)

test("drop table CASCADE: postgresql omits CASCADE when not referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "postgresql", false)
  eq(ddl_sql, 'DROP TABLE "users"', "postgresql, no referencing FKs")
end)

test("drop table CASCADE: sqlite never appends CASCADE, even when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "sqlite", true)
  eq(ddl_sql, 'DROP TABLE "users"', "sqlite has no CASCADE syntax")
end)

test("drop table CASCADE: mysql never appends CASCADE, even when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "mysql", true)
  eq(ddl_sql, 'DROP TABLE "users"', "mysql ignores CASCADE silently, so we must not send it")
end)

test("drop table CASCADE: sqlserver never appends CASCADE, even when referenced", function()
  local ddl_sql = ddl._build_drop_sql("users", "sqlserver", true)
  eq(ddl_sql, 'DROP TABLE "users"', "sqlserver has no CASCADE syntax")
end)

test("drop table CASCADE: unknown/nil kind never appends CASCADE", function()
  local ddl_sql = ddl._build_drop_sql("users", nil, true)
  eq(ddl_sql, 'DROP TABLE "users"', "unresolved adapter kind must not get CASCADE")
end)

-- ── drop table: referencing-FK filter (M._filter_referencing) ───────────────
-- drop_table replaced its N+1 per-table FK scan with one call to
-- db.get_referencing_foreign_keys(). That query is schema-exact on
-- postgresql/mysql/duckdb/sqlite; sqlserver has no dedicated implementation
-- and falls back (in db.lua) to a bare-name scan that can't distinguish two
-- same-named tables in different schemas. _filter_referencing is the guard
-- that keeps that one combination from widening past the old scan's strictness.

test("filter_referencing: bare table name is never filtered, any kind", function()
  -- A trailing nil in the list literal would end ipairs early and silently skip
  -- the unresolved-kind case, so it is asserted separately below the loop.
  local refs = { { table = "orders", column = "user_id", ref_column = "id" } }
  for _, kind in ipairs({ "postgresql", "mysql", "duckdb", "sqlite", "sqlserver" }) do
    local out = ddl._filter_referencing(refs, "users", kind)
    eq(#out, 1, "kind=" .. kind)
  end
  eq(#ddl._filter_referencing(refs, "users", nil), 1, "kind=nil")
end)

test("filter_referencing: schema-qualified name kept for schema-exact adapters", function()
  local refs = { { table = "orders", column = "user_id", ref_column = "id" } }
  for _, kind in ipairs({ "postgresql", "mysql", "duckdb", "sqlite" }) do
    local out = ddl._filter_referencing(refs, "public.users", kind)
    eq(#out, 1, "kind=" .. kind .. " should keep exact-schema matches")
  end
end)

test("filter_referencing: schema-qualified name dropped for adapters without a dedicated query", function()
  local refs = { { table = "orders", column = "user_id", ref_column = "id" } }
  local out = ddl._filter_referencing(refs, "dbo.users", "sqlserver")
  eq(#out, 0, "sqlserver bare-name fallback can't be trusted for a qualified name")
end)

test("filter_referencing: unresolved/unknown kind treated like a non-exact adapter", function()
  local refs = { { table = "orders", column = "user_id", ref_column = "id" } }
  local out = ddl._filter_referencing(refs, "sales.users", nil)
  eq(#out, 0, "unknown kind + qualified name is filtered defensively")
end)

test("filter_referencing: empty input stays empty", function()
  local out = ddl._filter_referencing({}, "schema.users", "sqlserver")
  eq(#out, 0, "nothing to filter")
end)

-- A self-reference (employees.manager_id -> employees.id) is not an inbound
-- dependency: dropping the table drops its own constraint. No adapter's
-- reverse-FK query excludes it, but the old per-table scan did, so the filter
-- has to. Counting it would append CASCADE on postgresql/duckdb for every
-- table with a parent_id/manager_id column.

test("filter_referencing: self-reference is not an inbound dependency, any kind", function()
  local refs = { { table = "employees", column = "manager_id", ref_column = "id" } }
  for _, kind in ipairs({ "postgresql", "mysql", "duckdb", "sqlite", "sqlserver" }) do
    local out = ddl._filter_referencing(refs, "employees", kind)
    eq(#out, 0, "kind=" .. kind .. " must not treat a self-FK as a dependent")
  end
  local out = ddl._filter_referencing(refs, "employees", nil)
  eq(#out, 0, "kind=nil must not treat a self-FK as a dependent")
end)

test("filter_referencing: self-reference dropped, genuine inbound FK kept", function()
  local refs = {
    { table = "employees", column = "team_id", ref_column = "id" },
    { table = "teams", column = "parent_team_id", ref_column = "id" },
  }
  local out = ddl._filter_referencing(refs, "teams", "postgresql")
  eq(#out, 1, "only the self-FK is filtered")
  eq(out[1].table, "employees", "the real dependent survives")
end)

test("filter_referencing: self-reference matched on bare name across schemas", function()
  -- postgresql returns child tables schema-qualified; the drop target may be
  -- bare (public) or qualified, so both directions must recognise the self-FK.
  local qualified = { { table = "sales.orders", column = "parent_id", ref_column = "id" } }
  eq(#ddl._filter_referencing(qualified, "sales.orders", "postgresql"), 0, "both qualified")
  eq(#ddl._filter_referencing(qualified, "orders", "postgresql"), 0, "target bare")
  local plain = { { table = "orders", column = "parent_id", ref_column = "id" } }
  eq(#ddl._filter_referencing(plain, "public.orders", "postgresql"), 0, "row bare")
end)

-- ── DDL SQL patterns: add column ─────────────────────────────────────────────

test("add column SQL: basic format", function()
  local parts = { "ALTER TABLE " .. sql.quote_ident("users") }
  local col_def = "ADD COLUMN " .. sql.quote_ident("bio") .. " text"
  table.insert(parts, col_def)
  local ddl_sql = table.concat(parts, " ")
  contains(ddl_sql, 'ALTER TABLE "users" ADD COLUMN "bio" text', "add column")
end)

test("add column SQL: with DEFAULT clause", function()
  local parts = { "ALTER TABLE " .. sql.quote_ident("users") }
  local col_def = "ADD COLUMN " .. sql.quote_ident("status") .. " text"
  col_def = col_def .. " DEFAULT " .. sql.quote_value("active")
  table.insert(parts, col_def)
  local ddl_sql = table.concat(parts, " ")
  contains(ddl_sql, "DEFAULT 'active'", "default value")
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nddl_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
