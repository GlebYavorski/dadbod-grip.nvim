-- Minimal init for headless testing: loads plugin from repo root
vim.opt.rtp:prepend(".")
-- Shared spec assertions live in tests/helpers.lua and are pulled in with
-- require("helpers"). The directory is resolved from this file's own path, so
-- the name works no matter which cwd nvim was launched from.
package.path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  .. "/?.lua;" .. package.path
-- Do not call setup() for pure module tests
