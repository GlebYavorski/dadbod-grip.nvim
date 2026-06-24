-- schema_routines_spec.lua: schema browser routine node rendering.
dofile("tests/minimal_init.lua")

local schema = require("dadbod-grip.schema")

local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

test("build_nodes renders functions and procedures after tables", function()
  local state = {
    items = {
      { type = "table", name = "users" },
      { type = "view", name = "active_users" },
    },
    routines = {
      { type = "function", name = "user_display_name", display = "user_display_name(user_id integer)" },
      { type = "procedure", name = "mark_order_status", display = "mark_order_status(order_id integer, new_status text)" },
    },
    expanded = {},
    col_cache = {},
    pk_cache = {},
    fk_cache = {},
    row_count_cache = {},
  }

  local nodes = schema._build_nodes(state)
  local seen = {}
  for _, node in ipairs(nodes) do
    if node.kind == "header" then seen[node.text] = true end
    if node.kind == "routine" then seen[node.type .. ":" .. node.name] = node.display end
  end

  assert(seen["Tables (1)"], "tables header rendered")
  assert(seen["Views (1)"], "views header rendered")
  assert(seen["Functions (1)"], "functions header rendered")
  assert(seen["Procedures (1)"], "procedures header rendered")
  assert(seen["function:user_display_name"] == "user_display_name(user_id integer)", "function node rendered")
  assert(seen["procedure:mark_order_status"] == "mark_order_status(order_id integer, new_status text)", "procedure node rendered")
end)

test("build_nodes filters routines by name and display", function()
  local state = {
    items = { { type = "table", name = "users" } },
    routines = {
      { type = "function", name = "user_display_name", display = "user_display_name(user_id integer)" },
      { type = "procedure", name = "mark_order_status", display = "mark_order_status(order_id integer, new_status text)" },
    },
    filter = "status",
    expanded = {},
    col_cache = {},
    pk_cache = {},
    fk_cache = {},
    row_count_cache = {},
  }

  local nodes = schema._build_nodes(state)
  local found_status = false
  local found_display = false
  for _, node in ipairs(nodes) do
    if node.kind == "table" and node.name == "users" then
      found_display = true
    end
    if node.kind == "routine" and node.name == "mark_order_status" then
      found_status = true
    end
  end

  assert(found_status, "matching routine remains visible")
  assert(not found_display, "non-matching table is filtered out")
end)

print(string.format("\nschema_routines_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
