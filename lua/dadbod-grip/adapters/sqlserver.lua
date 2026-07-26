-- adapters/sqlserver.lua: SQL Server adapter (sqlcmd CLI).
-- Read-only grid support for v1. All functions return (result, err).

local adapters = require("dadbod-grip.adapters")
local sql_util = require("dadbod-grip.sql")
local esc = sql_util.escape_literal

local M = { readonly = true }

local DEFAULT_TIMEOUT = 30000

--- Parse a dadbod-style SQL Server URL into connection components.
--- "sqlserver://user:pass@host:port/dbname" → {user, pass, host, port, dbname}
local function parse_url(url)
  return sql_util.parse_dadbod_url(url, "1433")
end

--- Split a possibly schema-qualified table name; unqualified names are "dbo".
local function split_table_name(table_name, default_schema)
  return sql_util.split_table_name(table_name, default_schema or "dbo")
end

local function sqlcmd(parsed, sql_str, timeout_ms)
  local server = parsed.host or "127.0.0.1"
  if parsed.port and parsed.port ~= "" then
    server = server .. "," .. parsed.port
  end

  local args = {
    "sqlcmd",
    "-S", server,
    "-W",
    "-s", "\t",
    "-Q", "SET NOCOUNT ON;\n" .. sql_str,
  }

  if parsed.dbname and parsed.dbname ~= "" then
    table.insert(args, 4, parsed.dbname)
    table.insert(args, 4, "-d")
  end

  if parsed.user and parsed.user ~= "" then
    table.insert(args, 4, parsed.pass or "")
    table.insert(args, 4, "-P")
    table.insert(args, 4, parsed.user)
    table.insert(args, 4, "-U")
  else
    table.insert(args, 4, "-E")
  end

  return adapters.run_cmd(args, timeout_ms or DEFAULT_TIMEOUT)
end

local function parse_sqlcmd_table(raw)
  if not raw or raw == "" then
    return { columns = {}, rows = {} }
  end

  local lines = {}
  for line in raw:gmatch("[^\r\n]+") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^%(%d+ rows? affected%)$") then
      table.insert(lines, line)
    end
  end
  if #lines == 0 then return { columns = {}, rows = {} } end

  local function split(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
      field = vim.trim(field)
      if field == "NULL" then field = "" end
      table.insert(fields, field)
    end
    return fields
  end

  local columns = split(lines[1])
  local rows = {}
  for i = 2, #lines do
    local sep_probe = lines[i]:gsub("[\t%s%-]", "")
    if not (sep_probe == "" and lines[i]:find("-", 1, true)) then
      local row = split(lines[i])
      while #row < #columns do table.insert(row, "") end
      table.insert(rows, row)
    end
  end

  return { columns = columns, rows = rows }
end

local function run_query(sql_str, url, timeout_ms)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end

  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid SQL Server URL: " .. url end

  local stdout, stderr, code = sqlcmd(parsed, sql_str, timeout_ms)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or ("sqlcmd exited with code " .. code)
  end
  return parse_sqlcmd_table(stdout), nil
end

function M.query(sql_str, url)
  local parsed, err = run_query(sql_str, url)
  if not parsed then return nil, err end
  return {
    rows = parsed.rows,
    columns = parsed.columns,
    primary_keys = {},
  }, nil
end

function M.execute(sql_str, url)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end
  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid SQL Server URL: " .. url end
  local stdout, stderr, code = sqlcmd(parsed, sql_str)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or ("sqlcmd exited with code " .. code)
  end
  local n = stdout:match("%((%d+) rows? affected%)") or stderr:match("%((%d+) rows? affected%)") or "0"
  return { affected = tonumber(n) or 0, message = stdout:gsub("%s+$", "") }, nil
end

function M.ping(url)
  if vim.fn.executable("sqlcmd") == 0 then return false end
  local parsed = parse_url(url)
  if not parsed then return false end
  local _, _, code = sqlcmd(parsed, "SELECT 1", 5000)
  return code == 0
end

function M.list_tables(url)
  local result, err = run_query([[
    SELECT
      CASE WHEN TABLE_SCHEMA = 'dbo' THEN TABLE_NAME ELSE TABLE_SCHEMA + '.' + TABLE_NAME END AS table_name,
      CASE TABLE_TYPE WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_TYPE IN ('BASE TABLE', 'VIEW')
    ORDER BY TABLE_SCHEMA, table_type DESC, TABLE_NAME
  ]], url)
  if not result then return nil, err end
  local out = {}
  for _, row in ipairs(result.rows) do
    table.insert(out, { name = row[1] or "", type = row[2] or "table" })
  end
  return out, nil
end

function M.get_column_info(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      COLUMN_NAME,
      DATA_TYPE +
        CASE
          WHEN CHARACTER_MAXIMUM_LENGTH IS NOT NULL AND CHARACTER_MAXIMUM_LENGTH > 0
            THEN '(' + CAST(CHARACTER_MAXIMUM_LENGTH AS varchar(20)) + ')'
          WHEN NUMERIC_PRECISION IS NOT NULL AND DATA_TYPE NOT IN ('int','bigint','smallint','tinyint','bit')
            THEN '(' + CAST(NUMERIC_PRECISION AS varchar(20)) +
                 CASE WHEN NUMERIC_SCALE > 0 THEN ',' + CAST(NUMERIC_SCALE AS varchar(20)) ELSE '' END + ')'
          ELSE ''
        END AS data_type,
      IS_NULLABLE,
      COALESCE(COLUMN_DEFAULT, '') AS column_default,
      ''
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = '%s'
      AND TABLE_NAME = '%s'
    ORDER BY ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return nil, err end

  local cols = {}
  for _, row in ipairs(result.rows) do
    table.insert(cols, {
      column_name = row[1] or "",
      data_type = row[2] or "",
      is_nullable = row[3] or "",
      column_default = row[4] or "",
      constraints = row[5] or "",
    })
  end
  return cols, nil
end

function M.get_primary_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT kcu.COLUMN_NAME
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
      ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
      AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
      AND tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
    ORDER BY kcu.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local pks = {}
  for _, row in ipairs(result.rows) do
    if row[1] and row[1] ~= "" then table.insert(pks, row[1]) end
  end
  return pks, nil
end

function M.get_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      kcu.COLUMN_NAME,
      ccu.TABLE_NAME AS ref_table,
      ccu.COLUMN_NAME AS ref_column
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
      ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
      AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
    JOIN INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
      ON rc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND rc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    JOIN INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE ccu
      ON ccu.CONSTRAINT_NAME = rc.UNIQUE_CONSTRAINT_NAME
      AND ccu.CONSTRAINT_SCHEMA = rc.UNIQUE_CONSTRAINT_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'FOREIGN KEY'
      AND tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
    ORDER BY kcu.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local fks = {}
  for _, row in ipairs(result.rows) do
    table.insert(fks, {
      column = row[1] or "",
      ref_table = row[2] or "",
      ref_column = row[3] or "",
    })
  end
  return fks, nil
end

function M.get_schema_batch(url)
  local result = run_query([[
    SELECT
      CASE WHEN TABLE_SCHEMA = 'dbo' THEN TABLE_NAME ELSE TABLE_SCHEMA + '.' + TABLE_NAME END AS table_name,
      COLUMN_NAME,
      DATA_TYPE,
      IS_NULLABLE
    FROM INFORMATION_SCHEMA.COLUMNS
    ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
  ]], url)
  if not result then return nil end
  local tables = {}
  for _, row in ipairs(result.rows) do
    local tname = row[1] or ""
    tables[tname] = tables[tname] or {}
    table.insert(tables[tname], {
      column_name = row[2] or "",
      data_type = row[3] or "",
      is_nullable = row[4] or "",
    })
  end
  return tables
end

function M.get_indexes(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      i.name AS index_name,
      CASE WHEN i.is_primary_key = 1 THEN 'PRIMARY'
           WHEN i.is_unique = 1 THEN 'UNIQUE'
           ELSE 'INDEX' END AS index_type,
      STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS columns
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    JOIN sys.objects o ON o.object_id = i.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name = '%s'
      AND o.name = '%s'
      AND i.name IS NOT NULL
    GROUP BY i.name, i.is_primary_key, i.is_unique
    ORDER BY i.is_primary_key DESC, i.name
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local indexes = {}
  for _, row in ipairs(result.rows) do
    local cols = {}
    for col in (row[3] or ""):gmatch("([^,]+)") do table.insert(cols, vim.trim(col)) end
    table.insert(indexes, { name = row[1] or "", type = row[2] or "INDEX", columns = cols })
  end
  return indexes, nil
end

function M.get_constraints(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      tc.CONSTRAINT_NAME,
      tc.CONSTRAINT_TYPE,
      COALESCE(cc.CHECK_CLAUSE, '') AS definition
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    LEFT JOIN INFORMATION_SCHEMA.CHECK_CONSTRAINTS cc
      ON cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    WHERE tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
      AND tc.CONSTRAINT_TYPE IN ('CHECK', 'UNIQUE')
    ORDER BY tc.CONSTRAINT_TYPE, tc.CONSTRAINT_NAME
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local constraints = {}
  for _, row in ipairs(result.rows) do
    table.insert(constraints, { name = row[1] or "", type = row[2] or "", definition = row[3] or "" })
  end
  return constraints, nil
end

function M.get_table_stats(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      SUM(row_count) AS row_estimate,
      SUM(reserved_page_count) * 8192 AS size_bytes
    FROM sys.dm_db_partition_stats ps
    JOIN sys.objects o ON o.object_id = ps.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name = '%s'
      AND o.name = '%s'
      AND ps.index_id IN (0, 1)
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result or not result.rows[1] then return nil, err or "No stats found" end
  return {
    row_estimate = tonumber(result.rows[1][1]) or 0,
    size_bytes = tonumber(result.rows[1][2]) or 0,
  }, nil
end

function M.explain(sql_str, url)
  local result, err = run_query("SET SHOWPLAN_TEXT ON;\n" .. sql_str .. "\nSET SHOWPLAN_TEXT OFF;", url)
  if not result then return nil, err end
  local lines = {}
  for _, row in ipairs(result.rows) do
    table.insert(lines, table.concat(row, " | "))
  end
  return { lines = lines }, nil
end

M._parse_url = parse_url
M._parse_sqlcmd_table = parse_sqlcmd_table

return M
