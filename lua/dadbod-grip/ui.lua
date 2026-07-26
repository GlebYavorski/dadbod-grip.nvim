-- ui.lua: shared UI primitives for dadbod-grip.
-- Kept small: only patterns that are reused across modules.

local M = {}

--- Return the configured float border style.
--- Lazy-requires init to avoid circular dependency.
function M.border()
  return require("dadbod-grip").get_opts().border
end

--- Prompt on the cmdline; return nil when the user cancels.
---
--- vim.fn.input() signals a cancel two ways: <Esc> returns `cancelreturn`, while
--- <C-c> raises. Both mean nil here. An empty answer counts as a cancel too
--- unless `allow_empty` is set — which is what almost every prompt here wants.
---
--- vim.fn.input() and not vim.ui.input() on purpose: it always uses the native
--- cmdline, so it is never intercepted by dressing.nvim/noice floats.
---
--- @param opts table   prompt, default?, completion?, allow_empty?
--- @return string|nil  the answer, or nil if cancelled
function M.input(opts)
  local CANCEL = "\0"
  local ok, answer = pcall(vim.fn.input, {
    prompt       = opts.prompt,
    default      = opts.default,
    completion   = opts.completion,
    cancelreturn = CANCEL,
  })
  if not ok or answer == CANCEL then return nil end
  if answer == "" and not opts.allow_empty then return nil end
  return answer
end

--- Ask a yes/no question. Only a literal "y"/"yes" is a yes; anything else —
--- including an empty answer or a cancel — is a no.
--- @param prompt string  spell out the default, e.g. "Drop table? (y/N): "
--- @return boolean
function M.confirm(prompt)
  local answer = M.input({ prompt = prompt, allow_empty = true })
  return answer == "y" or answer == "yes"
end

--- Open an editor-relative float and return its window and buffer.
---
--- Covers only what the info floats across the plugin share: a scratch buffer,
--- centered geometry, style = "minimal" and the configured border. Sizing rules
--- stay with the caller — every float has its own idea of how wide it should be.
--- Keys left nil are not passed to nvim_open_win at all, so a caller that never
--- set `title`/`zindex` keeps the stock window it had before.
---
--- @param opts table
---   lines      string[]|nil  fill a fresh scratch buffer with these
---   buf        integer|nil   use this buffer instead of creating one (pass it
---                            when buffer options must be set before the window
---                            exists, e.g. filetype)
---   width      integer       required
---   height     integer       required
---   relative   string|nil    default "editor"
---   row, col   integer|nil   default: centered for width/height
---   enter      boolean|nil   focus the float (default true)
---   style, border, title, title_pos, zindex, footer, footer_pos
---                            forwarded as-is; style/border default to
---                            "minimal" / M.border()
--- @return integer win, integer buf
function M.info_float(opts)
  local buf = opts.buf
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    if opts.lines then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    end
  end

  local cfg = {
    relative  = opts.relative or "editor",
    width     = opts.width,
    height    = opts.height,
    row       = opts.row or math.floor((vim.o.lines   - opts.height) / 2),
    col       = opts.col or math.floor((vim.o.columns - opts.width) / 2),
    style     = opts.style or "minimal",
    border    = opts.border or M.border(),
    title     = opts.title,
    title_pos = opts.title_pos,
    zindex    = opts.zindex,
  }

  local enter = opts.enter ~= false

  -- A footer needs a border; fall back silently when nvim rejects the config
  -- (border = "none").
  if opts.footer then
    local with_footer = vim.tbl_extend("force", cfg,
      { footer = opts.footer, footer_pos = opts.footer_pos })
    local ok, win = pcall(vim.api.nvim_open_win, buf, enter, with_footer)
    if ok then return win, buf end
  end

  return vim.api.nvim_open_win(buf, enter, cfg), buf
end

--- Show an animated spinner float, run fn(), then clear the float.
---
--- IMPORTANT: fn() must be synchronous OR use vim.wait() for async work.
--- If fn() returns before work is done, the float closes prematurely.
--- For async callers (e.g. curl/jobstart), use this pattern inside fn():
---
---   local done = false
---   start_async(function(result) ... done = true end)
---   vim.wait(30000, function() return done end, 50)
---
--- The spinner (braille frames) animates during vim.system():wait() and
--- vim.wait() calls inside fn() because both pump the libuv event loop.
--- eventignore="all" suppresses plugin autocmds (WinNew/BufNew) that add
--- 200-400ms overhead from noice/treesitter/nvim-cmp handlers.
---
--- @param msg string
--- @param fn  function  must be synchronous or use vim.wait() internally
--- @return    any       all return values from fn() forwarded
function M.blocking(msg, fn)
  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local fi = 1

  local display = "  " .. msg
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  " .. display, "" })
  local w = math.min(vim.fn.strdisplaywidth(display) + 6, vim.o.columns - 4)

  -- Suppress plugin autocmds during float create to avoid 200-400ms overhead.
  local ei = vim.o.eventignore
  vim.o.eventignore = "all"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", style = "minimal", border = M.border(),
    width    = w, height = 3,
    row      = math.floor((vim.o.lines   - 3) / 2),
    col      = math.floor((vim.o.columns - w) / 2),
  })
  vim.o.eventignore = ei

  -- Flush to terminal NOW, before fn() runs.
  vim.api.nvim__redraw({ flush = true })

  -- Animate: timer fires during vim.system():wait() and vim.wait() event loop pumps.
  -- libuv timer callbacks are "fast events" - nvim API calls are forbidden there.
  -- vim.schedule_wrap defers the API work into the main loop, which pumps during wait().
  local timer = vim.uv.new_timer()
  timer:start(80, 80, vim.schedule_wrap(function()
    fi = (fi % #frames) + 1
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false,
        { "", "  " .. frames[fi] .. " " .. msg, "" })
      vim.api.nvim__redraw({ flush = true })
    end
  end))

  -- table.pack/table.unpack are Lua 5.2+; LuaJIT is 5.1.
  -- { pcall(fn) } => { ok, r1, r2, ... } or { false, errmsg }
  local rets = { pcall(fn) }
  local ok   = table.remove(rets, 1)

  timer:stop()
  timer:close()

  -- Close float, suppressing autocmds again.
  ei = vim.o.eventignore
  vim.o.eventignore = "all"
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  vim.o.eventignore = ei

  -- Flush the close to terminal so the float disappears before the next render.
  vim.api.nvim__redraw({ flush = true })

  if not ok then error(rets[1], 2) end
  return (table.unpack or unpack)(rets)
end

return M
