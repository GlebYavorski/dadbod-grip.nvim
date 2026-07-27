-- view/keymaps_ai.lua: The two AI entry points reachable from the grid.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local ui     = require("dadbod-grip.ui")

local M = {}

--- Ask the model for a query (A) or for staged rows to insert (GripFill).
function M.setup(bufnr, ctx)
  local kmap = ctx.kmap

  -- A: AI SQL generation
  kmap("ai", function()
    local ai = require("dadbod-grip.ai")
    if not ai.is_enabled() then
      vim.notify("AI is disabled. Enable it in setup({ ai = { ... } })", vim.log.levels.INFO)
      return
    end
    local session_ai = ctx.session()
    local s_url = session_ai and session_ai.state.url
    if not s_url then
      s_url = require("dadbod-grip.db").get_url()
    end
    if not s_url then
      vim.notify("No database connection for AI", vim.log.levels.WARN)
      return
    end
    ai.ask(s_url)
  end, "AI SQL generation")

  kmap("grid_fill", function()
    local input = ui.input({ prompt = "Rows to generate: ", default = "1" })
    if not input then return end
    local n = tonumber(input)
    if not n or n < 1 then
      vim.notify("Enter a number >= 1", vim.log.levels.INFO)
      return
    end
    require("dadbod-grip").do_fill_rows(math.min(50, n))
  end, "AI-generated staged rows (GripFill)")
end

return M
