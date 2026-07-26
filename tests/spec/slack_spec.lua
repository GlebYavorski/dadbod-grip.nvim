-- slack_spec.lua: TDD tests for M._distribute_slack
--
-- Bug: when the table is narrower than the window, leftover horizontal space is
-- handed to truncated columns. It expanded them by up to +20 regardless of how
-- much real content they held, so hiding columns (which frees space) ballooned
-- the survivors — e.g. `name` grew from 40 to 60 while its longest value was
-- only 44, padding every row with 16 dead cells. The fix caps expansion at each
-- column's true (unclamped) content width.
--
-- Widths here are the inner display widths per column; the layout adds +3 per
-- column for separators/sort markers, matching build_render().

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

local distribute = view._distribute_slack

test("does not expand a column past its true content width", function()
  local cols = { "id", "name", "externalId", "config", "stytchOrgId" }
  local widths  = { id = 5, name = 40, externalId = 13, config = 40, stytchOrgId = 14 }
  local natural = { id = 5, name = 44, externalId = 13, config = 66, stytchOrgId = 14 }
  distribute(cols, widths, natural, 40, 166, 20)
  eq(widths.name, 44, "name capped at its 44-wide content, not ballooned to 60")
  eq(widths.config, 60, "config still truncated (content 66) → uses full +20 slack share")
  eq(widths.externalId, 13, "uncapped column untouched")
end)

test("no expansion when there is no slack", function()
  local cols = { "a", "b" }
  local widths  = { a = 40, b = 40 }
  local natural = { a = 80, b = 80 }
  distribute(cols, widths, natural, 40, 50, 20)  -- available 50 < total 86
  eq(widths.a, 40, "a unchanged")
  eq(widths.b, 40, "b unchanged")
end)

test("only capped/truncated columns receive slack", function()
  local cols = { "a", "b" }
  local widths  = { a = 10, b = 40 }         -- a is not at the cap
  local natural = { a = 10, b = 90 }
  distribute(cols, widths, natural, 40, 200, 20)
  eq(widths.a, 10, "narrow column left alone")
  eq(widths.b, 60, "truncated column grows by the +20 per-column cap")
end)

test("capped column with no hidden content does not grow", function()
  local cols = { "a" }
  local widths  = { a = 40 }
  local natural = { a = 40 }                 -- content exactly at cap → room 0
  distribute(cols, widths, natural, 40, 200, 20)
  eq(widths.a, 40, "nothing to reveal, no padding added")
end)

print(string.format("\nslack_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
