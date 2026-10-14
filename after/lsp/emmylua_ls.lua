-- Ensure lazydev is available (it drives the library discovery) and start the
-- bridge, then expose the emmylua_ls config.
--
-- This file is executed while Neovim resolves `lsp/emmylua_ls.lua` from
-- 'runtimepath' -- i.e. *before* the client starts -- so the bridge's LspAttach
-- handler is always registered in time.
--
-- NOTE: Neovim asserts that every `lsp/<name>.lua` returns a table, so this
-- file must return one (even an empty table).

if not pcall(require, "lazydev") then
  vim.notify("emmylua_ls_bridge: lazydev.nvim is required for library discovery", vim.log.levels.ERROR)
end

require("emmylua_ls_bridge").setup()

local root_markers1 = {
  ".emmyrc.json",
  ".emmyrc.lua",
  ".luarc.json",
  ".luarc.jsonc",
}
local root_markers2 = {
  ".luacheckrc",
  ".stylua.toml",
  "stylua.toml",
  "selene.toml",
  "selene.yml",
}

---@type vim.lsp.Config
return {
  cmd = { "emmylua_ls" },
  filetypes = { "lua" },
  root_markers = { root_markers1, root_markers2, { ".git" } },
  workspace_required = false,
  settings = {
    emmylua = {
      codeLens = { enable = true },
      hint = { enable = true },
    },
  },
}
