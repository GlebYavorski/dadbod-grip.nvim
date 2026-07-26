-- sources/docker_localdb.lua: discover live local postgres containers.
--
-- Convention (DataGrip / Beekeeper compatible):
--   labels:
--     dev.localdb.kind:     postgres
--     dev.localdb.name:     "human-readable name"
--     dev.localdb.user:     "<db user>"
--     dev.localdb.database: "<db name>"
--     dev.localdb.password: "<plain text local-dev password>"
--
-- Picker open calls M.fetch(); we shell out to `docker ps`, parse the labels
-- and published ports, and return a list of {name, url, source} entries.
-- Result cached for 2 seconds so a rapid double-open does not re-shell.

local M = {}

-- 2 seconds in nanoseconds. Picker is meta-fast on cache hit; fresh on miss.
local TTL_NS = 2 * 1e9

M._cache = { ts = 0, value = {} }

--- Drop the TTL cache. Test-only.
function M._reset_cache()
  M._cache = { ts = 0, value = {} }
end

--- Run docker ps with the standard label filter. Returns {rows, err}.
--- rows is a list of decoded JSON objects (one per running container).
--- Errors are absorbed: missing docker, daemon down, etc. yield {{}, err}.
local function run_docker_ps()
  -- Pre-flight: skip the shell-out entirely when docker is not installed.
  if vim.fn.executable("docker") == 0 then
    return {}, "docker not on PATH"
  end

  local out = vim.fn.systemlist({
    "docker", "ps",
    "--filter", "label=dev.localdb.kind",
    "--format", "{{json .}}",
  })
  if vim.v.shell_error ~= 0 then
    return {}, "docker ps failed (daemon down?)"
  end

  local rows = {}
  for _, line in ipairs(out) do
    if line ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" then
        table.insert(rows, decoded)
      end
    end
  end
  return rows, nil
end

--- Parse the `Ports` field from docker ps. Returns the host port (number) or
--- nil. Examples:
---   "0.0.0.0:6810->5432/tcp"                        -> 6810
---   "0.0.0.0:6810->5432/tcp, :::6810->5432/tcp"     -> 6810 (first 5432)
---   "5432/tcp"                                       -> nil  (unpublished)
---   "0.0.0.0:6810->5432/tcp, 0.0.0.0:6811->5433/tcp" -> 6810 (5432 wins)
local function parse_ports(ports_str)
  if type(ports_str) ~= "string" or ports_str == "" then return nil end

  local first_published = nil
  for chunk in ports_str:gmatch("[^,]+") do
    local trimmed = chunk:gsub("^%s+", ""):gsub("%s+$", "")
    -- Match host_port -> 5432/tcp; the host portion may be IPv4 or IPv6.
    local host_port, container_port = trimmed:match("[%d%.:%[%]]*:(%d+)%-%>(%d+)/tcp$")
    if host_port and container_port then
      local hp = tonumber(host_port)
      if hp then
        if container_port == "5432" then return hp end
        first_published = first_published or hp
      end
    end
  end
  return first_published
end

--- Parse the `Labels` field. Docker emits this two ways depending on the
--- format template:
---   - `{{json .Labels}}`         yields a JSON object: { "k": "v", ... }
---   - `{{json .}}` (the row)     yields a comma-joined string: "k=v,k=v,..."
---
--- We use the row form so we can grab other fields in a single call. That
--- means Labels arrives as a string here. Our label keys are dotted ASCII
--- (`dev.localdb.kind` etc.) and the values for our use case are short
--- strings without commas, so a simple split on the FIRST comma between
--- entries is safe in practice.
local function parse_labels(labels)
  if type(labels) == "table" then return labels end  -- already decoded
  if type(labels) ~= "string" or labels == "" then return {} end
  local out = {}
  for chunk in labels:gmatch("[^,]+") do
    local k, v = chunk:match("^([^=]+)=(.*)$")
    if k and v then out[k] = v end
  end
  return out
end

--- Convert a single docker ps row into a connection entry, or nil if the row
--- is missing required labels.
local function row_to_connection(row)
  local labels = parse_labels(row.Labels)
  if labels["dev.localdb.kind"] ~= "postgres" then return nil end

  local name = labels["dev.localdb.name"]
  local user = labels["dev.localdb.user"]
  local db = labels["dev.localdb.database"]
  local password = labels["dev.localdb.password"]
  if not (name and user and db) then return nil end

  local host_port = parse_ports(row.Ports)
  if not host_port then return nil end

  local pw_segment = password and (":" .. password) or ""
  local url = string.format(
    "postgresql://%s%s@localhost:%d/%s",
    user, pw_segment, host_port, db
  )
  return { name = name, url = url, source = "docker" }
end

--- Public: return discovered connections, cached for 2s within a session.
function M.fetch()
  local now = vim.uv.hrtime()
  if (now - M._cache.ts) < TTL_NS then
    return { connections = M._cache.value, error = nil }
  end

  local rows, err = run_docker_ps()
  if err then
    M._cache = { ts = now, value = {} }
    return { connections = {}, error = err }
  end

  local connections = {}
  local seen_urls = {}
  for _, row in ipairs(rows) do
    local entry = row_to_connection(row)
    if entry and not seen_urls[entry.url] then
      seen_urls[entry.url] = true
      table.insert(connections, entry)
    end
  end

  -- Stable sort by name for picker UX. Dedupe colliding names by appending
  -- the host port from the URL.
  table.sort(connections, function(a, b) return a.name < b.name end)
  local name_counts = {}
  for _, c in ipairs(connections) do
    name_counts[c.name] = (name_counts[c.name] or 0) + 1
  end
  for _, c in ipairs(connections) do
    if name_counts[c.name] > 1 then
      local p = c.url:match(":(%d+)/")
      if p then c.name = c.name .. " (" .. p .. ")" end
    end
  end

  M._cache = { ts = now, value = connections }
  return { connections = connections, error = nil }
end

return M
