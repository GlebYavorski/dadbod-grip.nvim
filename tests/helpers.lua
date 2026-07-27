-- helpers.lua -- assertions shared by more than one spec.
--
-- Not a spec itself (run_specs.lua only globs tests/spec/*_spec.lua). Specs
-- pull it in with `require("helpers")`; tests/minimal_init.lua puts this
-- directory on package.path so that name resolves.

local M = {}

--- Strict UTF-8 validity check (unlike vim.str_utf_pos, which is lenient about
--- a truncated trailing multi-byte sequence). Catches alignment and truncation
--- code that byte-slices a multi-byte character in half.
--- @param s string
--- @return boolean
function M.is_valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len
    if b < 0x80 then len = 1
    elseif b >= 0xC2 and b <= 0xDF then len = 2
    elseif b >= 0xE0 and b <= 0xEF then len = 3
    elseif b >= 0xF0 and b <= 0xF4 then len = 4
    else return false end
    if i + len - 1 > n then return false end
    for k = 1, len - 1 do
      local cb = s:byte(i + k)
      if not cb or cb < 0x80 or cb > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

return M
