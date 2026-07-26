-- cell_end_spec.lua: TDD tests for M._cell_end_byte
--
-- Bug: pressing `e` (grid_col_end) never advanced out of a cell whose rendered
-- text ends in a multibyte glyph (the … truncation marker, or ·NULL·). bp.finish
-- points at that glyph's LAST byte, but a normal-mode cursor rests on the glyph's
-- FIRST byte, so `cursor < bp.finish` stayed true forever and `e` kept "moving to
-- the end" in place. This helper maps a cell's last byte to the start byte of the
-- character it belongs to — the furthest position the cursor can actually reach.
--
-- All offsets are 0-based (matching nvim_win_set_cursor column semantics).

local view = require("dadbod-grip.view")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local cell_end = view._cell_end_byte

test("ascii cell: last byte unchanged", function()
  eq(cell_end("abc", 2), 2, "single-byte char is its own start")
end)

test("cell ending in … (3-byte): snaps to glyph start", function()
  local s = "x" .. "…"              -- x=1 byte, …=3 bytes at offsets 1,2,3
  eq(cell_end(s, 3), 1, "last byte of … → start of …")
end)

test("cell ending in · (2-byte): snaps to glyph start", function()
  local s = "a" .. "·"              -- a=1 byte, ·=2 bytes at offsets 1,2
  eq(cell_end(s, 2), 1, "last byte of · → start of ·")
end)

test("finish landing on a middle continuation byte", function()
  local s = "a" .. "…" .. "b"       -- …at 1,2,3 ; b at 4
  eq(cell_end(s, 2), 1, "middle byte of … → start of …")
end)

test("finish past end of line is returned as-is (no crash)", function()
  eq(cell_end("abc", 10), 10, "out-of-range finish is a no-op")
end)

test("finish at 0 stays 0", function()
  eq(cell_end("abc", 0), 0, "first byte")
end)

print(string.format("\ncell_end_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
