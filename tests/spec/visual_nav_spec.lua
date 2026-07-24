-- visual_nav_spec.lua: TDD tests for M._clamp_data_line
--
-- Bug being fixed (issue #20): in the data grid, cursor navigation is clamped
-- to the data-row range in NORMAL mode but not in VISUAL mode, so `V` then `G`
-- (or j/k) overshoots past the last data row onto the separator/footer/hint
-- line. This pure helper computes the clamped target line that the visual-mode
-- G/gg/j/k handlers snap the cursor to.
--
-- Data-row range is [data_start, data_start + #ordered - 1]. The footer/hint
-- line lives below that range; the title/header/type/separator rows above it.

local view = require("dadbod-grip.view")

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

local clamp = view._clamp_data_line

-- Layout without type row: title/header/sep then data at line 4.
-- 3 data rows → data lines 4,5,6; footer/hint at 7.
local r = { data_start = 4, ordered = { 1, 2, 3 } }

test("clamp: line within data range is unchanged", function()
  eq(clamp(r, 5), 5)
end)

test("clamp: line below range (footer/hint) snaps to last data row", function()
  eq(clamp(r, 7), 6, "footer line 7 must clamp to last data row 6")
end)

test("clamp: G target (very large line) snaps to last data row", function()
  eq(clamp(r, 9999), 6, "G overshoot must clamp to last data row 6")
end)

test("clamp: separator line just above data snaps to first data row", function()
  eq(clamp(r, 3), 4, "separator line 3 must clamp to first data row 4")
end)

test("clamp: title line (1) snaps to first data row", function()
  eq(clamp(r, 1), 4)
end)

test("clamp: first and last data lines are fixed points", function()
  eq(clamp(r, 4), 4, "first data line")
  eq(clamp(r, 6), 6, "last data line")
end)

-- Layout WITH type row: data_start = 5, 2 data rows → data lines 5,6; footer 7.
local rt = { data_start = 5, ordered = { 1, 2 } }

test("clamp (type row): footer clamps to last data row", function()
  eq(clamp(rt, 7), 6)
end)

test("clamp (type row): above-data clamps to first data row", function()
  eq(clamp(rt, 3), 5)
end)

-- Empty result set: no data rows → clamp collapses to data_start.
local re = { data_start = 4, ordered = {} }

test("clamp: empty result set clamps to data_start", function()
  eq(clamp(re, 4), 4)
  eq(clamp(re, 99), 4)
end)

print("visual_nav_spec: " .. pass .. " passed, " .. fail .. " failed")
if fail > 0 then vim.cmd("cquit 1") end
