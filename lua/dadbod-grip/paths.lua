-- paths.lua: project-local storage locations.
-- Single source of truth for where grip keeps per-project state
-- (.grip/history.jsonl, .grip/filters.json, .grip/queries/, .grip/connections.json).

local M = {}

--- Find project root by walking up from cwd looking for .git or .grip.
--- Falls back to cwd when neither marker is found.
--- @return string absolute directory path
function M.project_root()
  local dir = vim.fn.getcwd()
  while dir ~= "/" do
    if vim.fn.isdirectory(dir .. "/.git") == 1 or vim.fn.isdirectory(dir .. "/.grip") == 1 then
      return dir
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  return vim.fn.getcwd()
end

--- The project's .grip directory (not created).
--- @return string
function M.grip_dir()
  return M.project_root() .. "/.grip"
end

--- Create a directory (and parents) if it does not exist yet.
--- @param dir string
function M.ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

return M
