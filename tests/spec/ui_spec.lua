-- ui_spec.lua: unit tests for ui.blocking() and ui.info_float()
dofile("tests/minimal_init.lua")
local ui = require("dadbod-grip.ui")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function win_count()
  return #vim.api.nvim_list_wins()
end

test("blocking: returns single value", function()
  local result = ui.blocking("test", function() return 42 end)
  eq(result, 42, "return value")
end)

test("blocking: returns multiple values", function()
  local a, b, c = ui.blocking("test", function() return 1, 2, 3 end)
  eq(a, 1, "first"); eq(b, 2, "second"); eq(c, 3, "third")
end)

test("blocking: no extra windows after success", function()
  local before = win_count()
  ui.blocking("test", function() return "ok" end)
  local after = win_count()
  eq(after, before, "window count unchanged after success")
end)

test("blocking: no extra windows after error", function()
  local before = win_count()
  pcall(ui.blocking, "test", function() error("intentional") end)
  local after = win_count()
  eq(after, before, "window count unchanged after error")
end)

test("blocking: error is re-raised", function()
  local ok, err = pcall(ui.blocking, "test", function() error("boom") end)
  eq(ok, false, "should error")
  assert(tostring(err):find("boom"), "error msg should contain 'boom'")
end)

test("blocking: nil return values handled", function()
  local a, b = ui.blocking("test", function() return nil, nil end)
  eq(a, nil, "first nil")
  eq(b, nil, "second nil")
end)

-- ── input / confirm ─────────────────────────────────────────────────────────

--- Answer the next prompt with `keys`, then run fn().
local function answering(keys, fn)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, false, true), "L", false)
  return fn()
end

test("input: returns the typed answer", function()
  eq(answering("hello<CR>", function() return ui.input({ prompt = "P: " }) end),
    "hello", "answer")
end)

test("input: an empty answer is a cancel by default", function()
  eq(answering("<CR>", function() return ui.input({ prompt = "P: " }) end),
    nil, "empty -> nil")
end)

test("input: allow_empty keeps an empty answer", function()
  eq(answering("<CR>", function()
    return ui.input({ prompt = "P: ", allow_empty = true })
  end), "", "empty -> empty string")
end)

test("input: <Esc> cancels even with allow_empty", function()
  eq(answering("<Esc>", function() return ui.input({ prompt = "P: " }) end),
    nil, "esc -> nil")
  eq(answering("<Esc>", function()
    return ui.input({ prompt = "P: ", allow_empty = true })
  end), nil, "esc -> nil with allow_empty")
end)

test("input: default is prefilled and editable", function()
  eq(answering("<CR>", function()
    return ui.input({ prompt = "P: ", default = "dflt" })
  end), "dflt", "default accepted as-is")
  eq(answering("!<CR>", function()
    return ui.input({ prompt = "P: ", default = "dflt" })
  end), "dflt!", "default can be appended to")
end)

test("input: never propagates the <C-c> error", function()
  local real = vim.fn.input
  vim.fn.input = function() error("Keyboard interrupt") end
  local ok, res = pcall(ui.input, { prompt = "P: " })
  vim.fn.input = real
  eq(ok, true, "no error escapes")
  eq(res, nil, "interrupt -> nil")
end)

test("confirm: only y/yes is a yes", function()
  for _, answer in ipairs({ "y", "yes" }) do
    eq(answering(answer .. "<CR>", function()
      return ui.confirm("Q? (y/N): ")
    end), true, answer .. " -> true")
  end
  for _, answer in ipairs({ "n", "no", "Y", "YES", "maybe" }) do
    eq(answering(answer .. "<CR>", function()
      return ui.confirm("Q? (y/N): ")
    end), false, answer .. " -> false")
  end
end)

test("confirm: empty answer and cancel are both a no", function()
  eq(answering("<CR>", function() return ui.confirm("Q? (y/N): ") end),
    false, "empty -> false")
  eq(answering("<Esc>", function() return ui.confirm("Q? (y/N): ") end),
    false, "esc -> false")
end)

-- ── info_float ──────────────────────────────────────────────────────────────

vim.o.lines   = 40
vim.o.columns = 120

--- Open a float, hand (win, buf, config) to fn, then always clean up.
local function with_float(opts, fn)
  local win, buf = ui.info_float(opts)
  local ok, err = pcall(fn, win, buf, vim.api.nvim_win_get_config(win))
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then error(err, 0) end
end

test("info_float: fills a fresh scratch buffer with lines", function()
  with_float({ lines = { "a", "b" }, width = 20, height = 2 }, function(_, buf)
    local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq(#got, 2, "line count"); eq(got[1], "a", "line 1"); eq(got[2], "b", "line 2")
    eq(vim.bo[buf].buflisted, false, "scratch buffer is unlisted")
  end)
end)

test("info_float: centers on the editor by default", function()
  with_float({ lines = { "x" }, width = 40, height = 10 }, function(_, _, cfg)
    eq(cfg.relative, "editor", "relative")
    eq(cfg.row, math.floor((40 - 10) / 2), "row centered")
    eq(cfg.col, math.floor((120 - 40) / 2), "col centered")
    eq(cfg.style, "minimal", "style")
  end)
end)

test("info_float: explicit row/col win over centering", function()
  with_float({ lines = { "x" }, width = 30, height = 4, row = 0, col = 7 },
    function(_, _, cfg)
      eq(cfg.row, 0, "row"); eq(cfg.col, 7, "col")
    end)
end)

test("info_float: a nil title leaves the window untitled", function()
  with_float({ lines = { "x" }, width = 20, height = 2 }, function(_, _, cfg)
    eq(cfg.title, nil, "no title")
    eq(cfg.title_pos, nil, "no title_pos")
  end)
end)

test("info_float: title and zindex are forwarded", function()
  with_float({ lines = { "x" }, width = 20, height = 2,
               title = " T ", title_pos = "center", zindex = 70 },
    function(_, _, cfg)
      eq(cfg.title[1][1], " T ", "title text")
      eq(cfg.title_pos, "center", "title_pos")
      eq(cfg.zindex, 70, "zindex")
    end)
end)

test("info_float: reuses a caller-supplied buffer", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "sql"
  with_float({ buf = buf, width = 20, height = 2 }, function(_, got)
    eq(got, buf, "same buffer")
    eq(vim.bo[got].filetype, "sql", "filetype preserved")
  end)
end)

test("info_float: footer survives a bordered window", function()
  with_float({ lines = { "x" }, width = 30, height = 2,
               footer = " f ", footer_pos = "center", border = "rounded" },
    function(_, _, cfg)
      eq(cfg.footer[1][1], " f ", "footer text")
      eq(cfg.footer_pos, "center", "footer_pos")
    end)
end)

test("info_float: footer is dropped when the border cannot carry it", function()
  -- border = "none" makes nvim reject footer: the float must still open.
  with_float({ lines = { "x" }, width = 30, height = 2,
               footer = " f ", footer_pos = "center", border = "none" },
    function(win, _, cfg)
      assert(vim.api.nvim_win_is_valid(win), "float opened without the footer")
      eq(cfg.footer, nil, "footer dropped")
    end)
end)

test("info_float: enter = false keeps the current window focused", function()
  local before = vim.api.nvim_get_current_win()
  with_float({ lines = { "x" }, width = 20, height = 2, enter = false }, function(win)
    assert(win ~= before, "a new window was opened")
    eq(vim.api.nvim_get_current_win(), before, "focus unchanged")
  end)
end)

test("info_float: entered by default", function()
  local before = vim.api.nvim_get_current_win()
  with_float({ lines = { "x" }, width = 20, height = 2 }, function(win)
    eq(vim.api.nvim_get_current_win(), win, "float is focused")
  end)
  eq(vim.api.nvim_get_current_win(), before, "focus restored after close")
end)

print(string.format("ui_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
