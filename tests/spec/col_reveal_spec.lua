-- col_reveal_spec.lua: TDD tests for M._reveal_leftcol
--
-- Feature: pressing `$` (grid_col_last) jumps to the start of the last column,
-- but Neovim's default sidescroll leaves the column's right edge off-screen for
-- wide tables. This pure helper computes the horizontal scroll offset (leftcol)
-- that brings the column's right edge into view while keeping its start visible.
--
-- All display columns are 1-based; leftcol/textwidth are screen-cell counts.
-- A display column c is visible iff leftcol < c <= leftcol + textwidth.
-- Returns the new leftcol, or nil when no horizontal scroll is needed.

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

local reveal = view._reveal_leftcol

test("nil when right edge already visible", function()
  -- column [60,75] within visible range (0,80] → nothing to do
  eq(reveal(0, 80, 60, 75), nil, "fits")
end)

test("nil at exact right boundary", function()
  -- finish == leftcol + textwidth is still visible
  eq(reveal(30, 40, 50, 70), nil, "finish flush at right edge counts as visible")
end)

test("scrolls so the right edge sits at the window's right", function()
  -- column [50,70], textwidth 40, no scroll yet → leftcol = 70-40 = 30
  eq(reveal(0, 40, 50, 70), 30, "finish at right edge")
end)

test("keeps the column start visible for wide columns", function()
  -- column [50,90] wider than textwidth 20 → cannot show both; keep start visible
  eq(reveal(0, 20, 50, 90), 49, "clamp to start_vcol - 1")
end)

test("adjusts when already partially scrolled", function()
  -- leftcol 10, visible right = 50, finish 60 off-screen → leftcol = 60-40 = 20
  eq(reveal(10, 40, 45, 60), 20, "re-scroll to reveal finish")
end)

test("never returns a negative leftcol", function()
  eq(reveal(0, 100, 3, 120), 2, "clamped by start, non-negative")
  -- wide column, start at display col 1: floors leftcol at 0 (scroll back left)
  eq(reveal(3, 5, 1, 100), 0, "start at col 1 → floor at 0")
end)

test("nil when already scrolled and finish visible", function()
  -- leftcol 30, visible range (30,70]; column [55,68] fully visible → nil
  eq(reveal(30, 40, 55, 68), nil, "no movement needed")
end)

test("nil for non-positive textwidth", function()
  eq(reveal(0, 0, 1, 10), nil, "degenerate window")
end)

test("margin reveals extra columns for the trailing border glyph", function()
  -- column [50,70], textwidth 40, margin 2: reveal to 72 → leftcol = 72-40 = 32
  eq(reveal(0, 40, 50, 70, 2), 32, "seat border (finish+2) at the right edge")
end)

test("margin triggers a scroll when only the border is off-screen", function()
  -- data ends exactly at the right edge (70) but the border at 72 is hidden
  eq(reveal(30, 40, 50, 70, 2), 32, "scroll the extra 2 cols to show the border")
end)

test("margin: nil when border already visible", function()
  -- finish 66 + margin 2 = 68, within visible (30,70] → no scroll
  eq(reveal(30, 40, 50, 66, 2), nil, "border already on screen")
end)

test("margin never scrolls the column start off-screen", function()
  -- wide column [50,90], textwidth 20, margin 2 → still clamp to start_vcol - 1
  eq(reveal(0, 20, 50, 90, 2), 49, "start visibility wins over border margin")
end)

print(string.format("\ncol_reveal_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
