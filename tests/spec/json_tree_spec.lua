-- json_tree_spec.lua: JSON path drilldown tree (gK).
--
-- Pure logic: parse, kind detection, sorted children, JSONPath generation,
-- build_lines with expand/collapse state, leaf counting, auto-expand rule,
-- scalar rendering (null/bool/number/string), yank text.
-- UI smoke: open the float on a JSON cell straight from the sqlite seed.

local jt   = require("dadbod-grip.json_tree")
local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")

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

local function truthy(a, msg)
  assert(a, (msg or "") .. ": expected truthy, got " .. tostring(a))
end

local function contains(s, needle, msg)
  assert(type(s) == "string" and s:find(needle, 1, true),
    (msg or "") .. ": expected '" .. tostring(s) .. "' to contain '" .. tostring(needle) .. "'")
end

-- ── parse ────────────────────────────────────────────────────────────────────

test("parse: JSON object decodes to a table", function()
  local d = jt.parse('{"a": 1}')
  eq(type(d), "table", "decoded type")
end)

test("parse: JSON array decodes to a table", function()
  local d = jt.parse('[1, 2]')
  eq(type(d), "table", "decoded type")
end)

test("parse: leading/trailing whitespace still parses", function()
  truthy(jt.parse('  {"a": 1}  '), "whitespace-wrapped object")
end)

test("parse: invalid JSON returns nil", function()
  eq(jt.parse("{oops"), nil, "invalid")
end)

test("parse: bare scalar is not drillable", function()
  eq(jt.parse("123"), nil, "number")
  eq(jt.parse('"hello"'), nil, "string")
  eq(jt.parse("null"), nil, "null")
end)

test("parse: nil / non-string input returns nil", function()
  eq(jt.parse(nil), nil, "nil")
  eq(jt.parse(42), nil, "number input")
end)

-- ── kind detection ───────────────────────────────────────────────────────────

test("kind: object, array, empty variants", function()
  eq(jt._kind(vim.json.decode('{"a":1}')), "object", "object")
  eq(jt._kind(vim.json.decode('[1]')), "array", "array")
  eq(jt._kind(vim.json.decode('{}')), "object", "empty object")
  eq(jt._kind(vim.json.decode('[]')), "array", "empty array")
  eq(jt._kind(vim.NIL), "null", "vim.NIL")
  eq(jt._kind(true), "boolean", "boolean")
  eq(jt._kind(1.5), "number", "number")
  eq(jt._kind("s"), "string", "string")
end)

-- ── children: sorted keys, 0-based array indices ─────────────────────────────

test("children: object keys are sorted", function()
  local ch = jt._children(vim.json.decode('{"zeta":1,"alpha":2,"mid":3}'))
  eq(#ch, 3, "count")
  eq(ch[1].key, "alpha", "first")
  eq(ch[2].key, "mid", "second")
  eq(ch[3].key, "zeta", "third")
end)

test("children: array keys are 0-based numeric indices in order", function()
  local ch = jt._children(vim.json.decode('[10, 20, 30]'))
  eq(#ch, 3, "count")
  eq(ch[1].key, 0, "first index")
  eq(ch[3].key, 2, "last index")
  eq(ch[3].value, 30, "last value")
end)

-- ── JSONPath ─────────────────────────────────────────────────────────────────

test("jsonpath: identifier keys use dot notation", function()
  eq(jt._jsonpath("$", "items"), "$.items", "top level")
  eq(jt._jsonpath("$.items", "price"), "$.items.price", "nested")
  eq(jt._jsonpath("$", "_priv2"), "$._priv2", "underscore + digits")
end)

test("jsonpath: array indices use brackets", function()
  eq(jt._jsonpath("$.items", 2), "$.items[2]", "index")
  eq(jt._jsonpath("$", 0), "$[0]", "root array index")
end)

test("jsonpath: non-identifier keys use bracket-quoted syntax", function()
  eq(jt._jsonpath("$", "weird key"), '$["weird key"]', "space")
  eq(jt._jsonpath("$", "2fast"), '$["2fast"]', "leading digit")
  eq(jt._jsonpath("$", "a-b"), '$["a-b"]', "hyphen")
  eq(jt._jsonpath("$", 'has"quote'), '$["has\\"quote"]', "embedded quote escaped")
end)

-- ── leaf count + auto-expand rule ────────────────────────────────────────────

test("leaf_count: scalars count as 1", function()
  eq(jt._leaf_count(vim.json.decode('{"a":1,"b":{"c":2,"d":3}}')), 3, "nested")
  eq(jt._leaf_count(vim.json.decode('[1,2,3]')), 3, "array")
end)

test("leaf_count: empty containers count as 1 leaf", function()
  eq(jt._leaf_count(vim.json.decode('{"a":{},"b":[]}')), 2, "two empties")
end)

test("initial_expanded: small documents fully expanded", function()
  local d = vim.json.decode('{"a":{"b":{"c":1}},"d":[1,2]}')
  local exp = jt._initial_expanded(d)
  eq(exp["$"], true, "root")
  eq(exp["$.a"], true, "a")
  eq(exp["$.a.b"], true, "a.b")
  eq(exp["$.d"], true, "d")
end)

test("initial_expanded: >20 leaves collapses children", function()
  local parts = {}
  for i = 1, 21 do parts[#parts + 1] = '"k' .. string.format("%02d", i) .. '":' .. i end
  local d = vim.json.decode('{"sub":{' .. table.concat(parts, ",") .. '}}')
  local exp = jt._initial_expanded(d)
  eq(exp["$"], true, "root always expanded")
  eq(exp["$.sub"], nil, "child collapsed")
end)

-- ── build_lines ──────────────────────────────────────────────────────────────

test("build_lines: collapsed root renders one summary line", function()
  local d = vim.json.decode('{"a":1,"b":2}')
  local lines, nodes = jt._build_lines(d, {})
  eq(#lines, 1, "one line")
  contains(lines[1], "$", "root label")
  contains(lines[1], "{...} (2 keys)", "object summary")
  eq(nodes[1].path, "$", "root path")
  eq(nodes[1].expanded, false, "collapsed")
end)

test("build_lines: expanded root lists sorted children indented 2 spaces", function()
  local d = vim.json.decode('{"b":2,"a":1}')
  local lines, nodes = jt._build_lines(d, { ["$"] = true })
  eq(#lines, 3, "root + 2 children")
  contains(lines[2], "  ", "indent")
  contains(lines[2], "a: 1", "sorted first child")
  contains(lines[3], "b: 2", "second child")
  eq(nodes[2].path, "$.a", "child path")
end)

test("build_lines: nested collapsed object shows key count summary", function()
  local d = vim.json.decode('{"nested":{"x":1,"y":2,"z":3}}')
  local lines = jt._build_lines(d, { ["$"] = true })
  eq(#lines, 2, "nested stays collapsed")
  contains(lines[2], "nested: {...} (3 keys)", "summary with count")
end)

test("build_lines: array summary uses items, elements labeled [i]", function()
  local d = vim.json.decode('{"tags":["alpha","beta"]}')
  local lines = jt._build_lines(d, { ["$"] = true, ["$.tags"] = true })
  contains(lines[2], "tags: [...] (2 items)", "array summary")
  contains(lines[3], '[0]: "alpha"', "0-based element label")
  contains(lines[4], '[1]: "beta"', "second element")
end)

test("build_lines: singular counts (1 key / 1 item)", function()
  local d = vim.json.decode('{"o":{"a":1},"l":[1]}')
  local lines = jt._build_lines(d, { ["$"] = true })
  contains(lines[2], "(1 item)", "array singular")
  contains(lines[3], "(1 key)", "object singular")
end)

test("build_lines: two-space indent per depth level", function()
  local d = vim.json.decode('{"a":{"b":{"c":1}}}')
  local lines = jt._build_lines(d, { ["$"] = true, ["$.a"] = true, ["$.a.b"] = true })
  truthy(lines[2]:match("^  %S"), "depth 1 = 2 spaces: " .. lines[2])
  truthy(lines[3]:match("^    %S"), "depth 2 = 4 spaces: " .. lines[3])
  truthy(lines[4]:match("^      "), "depth 3 = 6 spaces: " .. lines[4])
end)

test("build_lines: expand markers on containers only", function()
  local d = vim.json.decode('{"a":{"x":1},"b":2}')
  local lines, nodes = jt._build_lines(d, { ["$"] = true })
  contains(lines[1], "▾", "expanded marker")
  contains(lines[2], "▸", "collapsed marker")
  eq(nodes[2].expandable, true, "container expandable")
  truthy(not nodes[3].expandable, "scalar not expandable")
end)

test("build_lines: null and booleans render as JSON literals", function()
  local d = vim.json.decode('{"n":null,"t":true,"f":false}')
  local lines, nodes = jt._build_lines(d, { ["$"] = true })
  contains(lines[2], "f: false", "false")
  contains(lines[3], "n: null", "vim.NIL renders as null")
  contains(lines[4], "t: true", "true")
  eq(nodes[3].val_hl, "GripNull", "null highlight group")
  eq(nodes[4].val_hl, "GripBoolTrue", "true highlight group")
  eq(nodes[2].val_hl, "GripBoolFalse", "false highlight group")
end)

test("build_lines: strings quoted, numbers plain", function()
  local d = vim.json.decode('{"s":"hi","i":3,"f":2.5}')
  local lines = jt._build_lines(d, { ["$"] = true })
  contains(lines[2], "f: 2.5", "float")
  contains(lines[3], "i: 3", "integer without decimals")
  contains(lines[4], 's: "hi"', "quoted string")
end)

test("build_lines: root array", function()
  local d = vim.json.decode('[{"a":1}]')
  local lines, nodes = jt._build_lines(d, { ["$"] = true })
  contains(lines[1], "[...] (1 item)", "root array summary")
  contains(lines[2], "[0]: {...} (1 key)", "collapsed element")
  eq(nodes[2].path, "$[0]", "element path")
end)

test("build_lines: non-identifier key gets bracket JSONPath on node", function()
  local d = vim.json.decode('{"weird key":{"x":1}}')
  local lines, nodes = jt._build_lines(d, { ["$"] = true })
  eq(nodes[2].path, '$["weird key"]', "bracket path")
  contains(lines[2], "weird key: {...}", "label shows raw key")
end)

-- ── yank text ────────────────────────────────────────────────────────────────

test("yank_text: scalars yank raw value", function()
  eq(jt._yank_text("hello"), "hello", "string unquoted")
  eq(jt._yank_text(42), "42", "number")
  eq(jt._yank_text(true), "true", "boolean")
  eq(jt._yank_text(vim.NIL), "null", "null")
end)

test("yank_text: containers yank compact JSON", function()
  local d = vim.json.decode('{"a":[1,2]}')
  eq(jt._yank_text(d.a), "[1,2]", "array encoded")
  contains(jt._yank_text(d), '"a":[1,2]', "object encoded")
end)

-- ── UI: float behavior ───────────────────────────────────────────────────────

local function cleanup()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

test("open: non-JSON value notifies and returns nil", function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  local win = jt.open("plain text")
  vim.notify = orig
  eq(win, nil, "no float")
  eq(notes[#notes], "Not a JSON cell", "notification")
end)

test("open: renders tree float with toggle, yank, and path yank", function()
  cleanup()
  local win, buf = jt.open('{"nested":{"deep":true},"key":"value"}', { title = " metadata (JSON) " })
  truthy(win and vim.api.nvim_win_is_valid(win), "float opened")
  eq(vim.api.nvim_get_current_win(), win, "float focused")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- 3 leaves <= 20 → fully expanded
  contains(lines[1], "{...} (2 keys)", "root summary")
  contains(lines[2], 'key: "value"', "scalar child")
  contains(lines[3], "nested: {...} (1 key)", "container child")
  contains(lines[4], "deep: true", "grandchild visible (auto-expand)")

  -- collapse "nested" via <CR>
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(#lines, 3, "grandchild hidden after collapse")

  -- re-expand via za, cursor stays on the node
  vim.api.nvim_feedkeys("za", "x", false)
  lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(#lines, 4, "grandchild visible again")
  eq(vim.api.nvim_win_get_cursor(win)[1], 3, "cursor kept on toggled node")

  -- y yanks the value under cursor (the nested object)
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  vim.api.nvim_feedkeys("y", "x", false)
  eq(vim.fn.getreg('"'), "true", "value yank")

  -- gy yanks the JSONPath
  vim.api.nvim_feedkeys("gy", "x", false)
  eq(vim.fn.getreg('"'), "$.nested.deep", "path yank")

  -- q closes
  vim.api.nvim_feedkeys("q", "x", false)
  eq(vim.api.nvim_win_is_valid(win), false, "closed")
  cleanup()
end)

test("open: >20 leaves opens with children collapsed", function()
  cleanup()
  local parts = {}
  for i = 1, 25 do parts[#parts + 1] = '"k' .. string.format("%02d", i) .. '":' .. i end
  local win, buf = jt.open('{"sub":{' .. table.concat(parts, ",") .. '}}')
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(#lines, 2, "root expanded, sub collapsed")
  contains(lines[2], "(25 keys)", "summary count")
  vim.api.nvim_win_close(win, true)
  cleanup()
end)

-- ── keymap registration + grid smoke test on the sqlite seed ────────────────

test("keymaps: grid_json_tree defaults to gK", function()
  eq(require("dadbod-grip.keymaps").defaults.grid_json_tree, "gK")
end)

test("grid gK on a json_data cell from the sqlite seed opens the tree", function()
  cleanup()
  local db   = require("dadbod-grip.db")
  local qmod = require("dadbod-grip.query")
  local url  = "sqlite:tests/seed_sqlite.db"
  local sql_str = qmod.build_sql(qmod.new_table("json_data", 100))
  local result, err = db.query(sql_str, url)
  assert(result, "query failed: " .. tostring(err))
  result.primary_keys = db.get_primary_keys("json_data", url) or {}
  result.table_name = "json_data"
  result.url = url
  result.sql = sql_str
  local state = data.new(result)
  local bufnr = view.open(state, url, sql_str)
  truthy(bufnr, "grid opened")

  -- move onto row 1, column "metadata"
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  local r = view._sessions[bufnr]._render
  local bp = r.byte_positions[1]["metadata"]
  vim.api.nvim_win_set_cursor(win, { (r.data_start or 4), bp.start })

  vim.api.nvim_feedkeys("gK", "x", false)
  local float_buf = vim.api.nvim_get_current_buf()
  truthy(float_buf ~= bufnr, "focus moved into tree float")
  local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
  local joined = table.concat(lines, "\n")
  contains(joined, 'key: "value"', "seed metadata key")
  contains(joined, "nested", "seed nested object")
  contains(joined, "deep: true", "seed nested leaf auto-expanded")
  vim.api.nvim_feedkeys("q", "x", false)
  cleanup()
end)

test("grid gK on a non-JSON cell notifies Not a JSON cell", function()
  cleanup()
  local st = data.new({
    columns = { "id", "name" },
    rows = { { "1", "alice" } },
    primary_keys = { "id" },
    table_name = "t",
    url = "sqlite:test.db",
  })
  local bufnr = view.open(st, st.url, "SELECT 1", {})
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  local r = view._sessions[bufnr]._render
  local bp = r.byte_positions[1]["name"]
  vim.api.nvim_win_set_cursor(win, { (r.data_start or 4), bp.start })
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  vim.api.nvim_feedkeys("gK", "x", false)
  vim.notify = orig
  eq(notes[#notes], "Not a JSON cell", "notification")
  cleanup()
end)

test("gK inside the K row view drills into the column under cursor", function()
  cleanup()
  local st = data.new({
    columns = { "id", "payload" },
    rows = { { "1", '{"a": {"b": 7}}' } },
    primary_keys = { "id" },
    table_name = "t",
    url = "sqlite:test.db",
  })
  local bufnr = view.open(st, st.url, "SELECT 1", {})
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  local r = view._sessions[bufnr]._render
  vim.api.nvim_win_set_cursor(win, { (r.data_start or 4), r.byte_positions[1]["id"].start })

  vim.api.nvim_feedkeys("K", "x", false)
  local row_view_buf = vim.api.nvim_get_current_buf()
  truthy(row_view_buf ~= bufnr, "row view opened")

  -- move onto the payload line (line 2 in the transpose) and press gK
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_feedkeys("gK", "x", false)
  local tree_buf = vim.api.nvim_get_current_buf()
  truthy(tree_buf ~= row_view_buf, "tree float opened from row view")
  local joined = table.concat(vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false), "\n")
  contains(joined, "b: 7", "drilled into payload JSON")
  vim.api.nvim_feedkeys("q", "x", false)
  cleanup()
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\njson_tree_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
