-- adapters/init.lua: adapter registry.
-- Detects DB type from URL scheme, returns the correct adapter module.

local M = {}

--- Run a CLI command and wait for it to finish, pumping the full Neovim event
--- loop during the wait. This allows vim.schedule_wrap timer callbacks (such as
--- the ui.blocking spinner) to fire while a CLI process is in progress.
---
--- vim.system():wait() only pumps libuv; vim.schedule_wrap callbacks live in the
--- Neovim main event queue and require vim.wait() to execute.
---
--- @param args  string[]   argv for vim.system
--- @param timeout_ms number|nil  process timeout in ms (default 30000)
--- @param opts table|nil  { stdin = string } to feed the process on stdin; the
---   sqlserver adapter needs it for GO-separated batches, which cannot be
---   expressed as a single command-line statement.
--- @return string stdout
--- @return string stderr
--- @return number exit_code
function M.run_cmd(args, timeout_ms, opts)
  local t = timeout_ms or 30000
  local out
  local done = false
  -- vim.system() raises on spawn failure (ENOENT when the CLI is not installed).
  -- Adapters promise never to throw, and only query/execute/ping pre-check
  -- vim.fn.executable(), so swallow it here and report it like a failed exit.
  local sys_opts = { text = true, timeout = t, stdin = opts and opts.stdin or nil }
  local ok, err = pcall(vim.system, args, sys_opts, function(r)
    out = r
    done = true
  end)
  if not ok then
    return "", tostring(err), 1
  end
  -- Poll at 1ms so done is detected immediately after the on_exit callback fires.
  -- The 80ms spinner timer fires when vim.wait pumps the event loop regardless of
  -- poll interval; tight polling just reduces per-call overhead in tests.
  -- Add 3s buffer beyond the process timeout to absorb on_exit callback latency.
  vim.wait(t + 3000, function() return done end, 1)
  local r = out or { stdout = "", stderr = "command timed out", code = 1 }
  return r.stdout or "", r.stderr or "", r.code
end

--- Non-blocking twin of M.run_cmd: spawns the process and delivers
--- (stdout, stderr, exit_code) to `callback` from the main Neovim loop via
--- vim.schedule, so the callback may touch buffers and Lua state freely.
--- Used by the get_schema_batch_async implementations that pre-warm the
--- completion cache; no vim.wait here, that is the whole point.
---
--- Same never-throw contract as M.run_cmd: vim.system() raises on spawn failure
--- (ENOENT when the CLI is not installed), so that is caught and reported as a
--- non-zero exit instead of escaping into the caller's callback-free stack.
---
--- @param args  string[]   argv for vim.system
--- @param timeout_ms number|nil  process timeout in ms (default 30000)
--- @param callback fun(stdout: string, stderr: string, code: number)
function M.run_cmd_async(args, timeout_ms, callback)
  local ok, err = pcall(vim.system, args, { text = true, timeout = timeout_ms or 30000 }, function(r)
    vim.schedule(function()
      callback(r.stdout or "", r.stderr or "", r.code)
    end)
  end)
  if not ok then
    vim.schedule(function() callback("", tostring(err), 1) end)
  end
end

local SCHEME_MAP = {
  ["postgresql://"] = "dadbod-grip.adapters.postgresql",
  ["postgres://"]   = "dadbod-grip.adapters.postgresql",
  ["sqlite:"]       = "dadbod-grip.adapters.sqlite",
  ["mysql://"]      = "dadbod-grip.adapters.mysql",
  ["mariadb://"]    = "dadbod-grip.adapters.mysql",
  ["duckdb:"]       = "dadbod-grip.adapters.duckdb",
  ["sqlserver://"]  = "dadbod-grip.adapters.sqlserver",
  ["mssql://"]      = "dadbod-grip.adapters.sqlserver",
}

--- Resolve the adapter module for a given connection URL.
--- @param url string
--- @return table|nil adapter module
--- @return string|nil error message
function M.resolve(url)
  if not url or url == "" then
    return nil, "No database URL provided"
  end
  for prefix, mod_name in pairs(SCHEME_MAP) do
    if url:sub(1, #prefix):lower() == prefix:lower() then
      local ok, adapter = pcall(require, mod_name)
      if not ok then
        return nil, "Failed to load adapter " .. mod_name .. ": " .. tostring(adapter)
      end
      return adapter, nil
    end
  end
  local scheme = url:match("^([^:]+:)") or url
  return nil, "Unsupported database scheme: " .. scheme
end

-- Human-readable adapter names, keyed by the kind M.kind() returns.
local DISPLAY_NAMES = {
  postgresql = "PostgreSQL",
  mysql      = "MySQL",
  sqlite     = "SQLite",
  duckdb     = "DuckDB",
  sqlserver  = "SQL Server",
}

--- Canonical adapter kind for a connection URL: "postgresql", "mysql",
--- "sqlite", "duckdb" or "sqlserver". Derived from SCHEME_MAP, so scheme
--- aliases (postgres, mariadb, mssql) collapse onto the owning adapter and
--- adding an adapter there is enough to teach every caller about it.
--- The bare "scheme:" form is accepted alongside "scheme://".
--- @param url string|nil
--- @return string|nil kind  nil when the scheme is unknown
function M.kind(url)
  if not url or url == "" then return nil end
  local u = url:lower()
  for prefix, mod_name in pairs(SCHEME_MAP) do
    local scheme = prefix:match("^([^:]+):")
    if scheme and u:sub(1, #scheme + 1) == scheme .. ":" then
      return mod_name:match("([^.]+)$")
    end
  end
  return nil
end

--- Human-readable adapter name for a connection URL ("PostgreSQL", ...).
--- @param url string|nil
--- @return string|nil  nil when the scheme is unknown
function M.display_name(url)
  local kind = M.kind(url)
  return kind and DISPLAY_NAMES[kind] or nil
end

return M
