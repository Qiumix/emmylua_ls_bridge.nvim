local M = {}

function M.check()
  local health = vim.health
  health.start("emmylua_ls_bridge")

  -- lazydev provides the workspace libraries.
  if package.loaded["lazydev.workspace"] then
    health.ok("lazydev.nvim is loaded")
  elseif pcall(require, "lazydev") then
    health.warn("lazydev.nvim is installed but `lazydev.workspace` is not loaded yet")
  else
    health.error("lazydev.nvim not found", {
      "emmylua_ls_bridge depends on folke/lazydev.nvim for library discovery",
      "Install it and add it to your plugin specs",
    })
  end

  -- Plugin loaded early enough for after/lsp/emmylua_ls.lua to run.
  if package.loaded["emmylua_ls_bridge"] then
    health.ok("bridge module loaded")
  else
    health.warn("bridge module not loaded (load this plugin *before* vim.lsp.enable, i.e. not lazily)")
  end

  local clients = vim.lsp.get_clients({ name = "emmylua_ls" })
  if #clients == 0 then
    health.info("no emmylua_ls client attached")
    return
  end

  health.ok(("%d emmylua_ls client(s) attached"):format(#clients))
  local libs = require("emmylua_ls_bridge").libraries()
  if #libs == 0 then
    health.info("no libraries discovered yet (open a Lua buffer that requires a plugin)")
  else
    health.info(("%d librar(y/ies) discovered:"):format(#libs))
    for _, lib in ipairs(libs) do
      health.info("  - " .. lib)
    end
  end
end

return M
