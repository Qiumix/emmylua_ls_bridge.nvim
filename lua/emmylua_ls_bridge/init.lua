--- Bridge lazydev's dynamic library discovery into emmylua_ls.
---
--- Stock emmylua_ls reads `Lua.workspace.library`, but for Neovim clients it
--- fetches both the `Lua` and `emmylua` scopes and keeps only the last non-empty
--- one (`default_config.rs`: `configs = fetched_configs`). Since this plugin (or
--- the user's LSP config) sets `emmylua.codeLens` / `emmylua.hint`, the `Lua`
--- scope is discarded. This module republishes the effective library list as
--- `emmylua.workspace.library`. Patched/newer servers merge both scopes, in
--- which case republishing is redundant but harmless.
---
--- It also extends lazydev's discovery with doc type references such as
--- `---@type zpack.Spec`, so `---@module "zpack"` is no longer required for
--- dotted plugin types.
local M = {}

--- client id -> key of the last library list pushed to it.
---@type table<integer, string>
local pushed = {}

--- Libraries discovered directly by the bridge (doc type references such as
--- `---@type zpack.Spec`). Kept separate from lazydev so the bridge does not
--- have to mutate lazydev's workspaces: mutating them triggers lazydev's own
--- `workspace/didChangeConfiguration` at the same time as the bridge's, and
--- emmylua_ls 0.30 can return an internal error for the next completion when
--- two config reloads race on a fresh buffer.
--- client id -> set of library roots.
---@type table<integer, table<string, true>>
local client_libs = {}

--- buffer -> true for buffers with an attached on_lines callback.
---@type table<integer, true>
local attached = {}

--- Extract dotted roots from a doc-comment line.
--- `---@type zpack.Spec` -> { "zpack" }
--- `---@param x table<string, zpack.Spec>` -> { "zpack" }
---@param line string
---@return string[]
local function scan_line(line)
  if not line:match("^%s*%-%-%-%s*@") then
    return {}
  end
  -- `@see` is a reference, not a type; avoid treating URLs as modules.
  if line:match("^%s*%-%-%-%s*@see") then
    return {}
  end
  local roots = {}
  local seen = {}
  -- Module names may contain hyphens (`which-key.Spec`, `render-markdown.Config`).
  for chain in line:gmatch("[%a_][%w_%-%.]*") do
    local mod = chain:match("^([%a_][%w_%-]*)%.")
    if mod and not seen[mod] then
      seen[mod] = true
      roots[#roots + 1] = mod
    end
  end
  return roots
end

--- Resolve a module name to a plugin's `lua/` directory.
--- Uses lazydev's resolver so loaded, unloaded, lazy.nvim and packpath layouts
--- all follow lazydev's existing rules.
---@param mod string
---@return string?
local function resolve_lib(mod)
  local ok, Pkg = pcall(require, "lazydev.pkg")
  if not ok then
    return nil
  end
  for _, root in ipairs(Pkg.find_roots(mod)) do
    -- Pkg.find_roots returns the module directory (without /init.lua).
    -- Use the last /lua/ so plugin paths containing /lua/ still work.
    local plugin = root:match("^(.*)/lua/")
    local lib = plugin and (plugin .. "/lua") or nil
    if lib and vim.fn.isdirectory(lib) == 1 then
      return vim.fs.normalize(lib)
    end
  end
end

---@param path string
---@param root string
---@return boolean
local function is_under(path, root)
  if not path or not root or path == "" or root == "" then
    return false
  end
  path = vim.fs.normalize(path)
  root = vim.fs.normalize(root)
  local prefix = root:gsub("/+$", "") .. "/"
  return path == root or path:sub(1, #prefix) == prefix
end

--- Workspace roots of a client. Libraries inside these roots are already part
--- of the workspace and must not be pushed as external libraries.
---@param client vim.lsp.Client
---@return string[]
local function client_roots(client)
  local roots = {}
  if client.root_dir and client.root_dir ~= "" then
    roots[#roots + 1] = vim.fs.normalize(client.root_dir)
  end
  for _, ws in ipairs(client.workspace_folders or {}) do
    local path = ws.uri and vim.uri_to_fname(ws.uri) or ws.name
    if path and path ~= "" then
      roots[#roots + 1] = vim.fs.normalize(path)
    end
  end
  return roots
end

---@param libs string[]
---@param seen table<string, true>
---@param path string?
---@param roots string[]
local function add_lib(libs, seen, path, roots)
  if type(path) ~= "string" or path == "" then
    return
  end
  path = vim.fn.expand(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if vim.fn.isdirectory(path) ~= 1 or seen[path] then
    return
  end
  for _, root in ipairs(roots) do
    if is_under(path, root) then
      return
    end
  end
  seen[path] = true
  libs[#libs + 1] = path
end

---@param settings table<string, any>
---@return string[]
local function settings_libraries(settings)
  local emmy = settings.emmylua
  local workspace = type(emmy) == "table" and emmy.workspace or nil
  local library = type(workspace) == "table" and workspace.library or nil
  return type(library) == "table" and library or {}
end

--- Effective libraries for one client:
--- - libraries already in its `emmylua` settings (including seed values);
--- - lazydev workspaces belonging to this client (`require` / `@module` refs);
--- - libraries the bridge discovered from doc type references.
--- lazydev's global workspace is intentionally not republished; those entries are
--- static libraries and belong in `.emmyrc.json`.
---@param client vim.lsp.Client
---@return string[]
local function client_libraries(client)
  local libs = {}
  local seen = {}
  local roots = client_roots(client)
  local settings = type(client.settings) == "table" and client.settings or {}

  for _, path in ipairs(settings_libraries(settings)) do
    add_lib(libs, seen, path, roots)
  end

  local ok, Workspace = pcall(require, "lazydev.workspace")
  if ok then
    for _, ws in pairs(Workspace.workspaces) do
      if ws.client_id == client.id and ws:enabled() then
        for _, path in ipairs(ws.library or {}) do
          add_lib(libs, seen, path, roots)
        end
      end
    end
  end

  for path in pairs(client_libs[client.id] or {}) do
    add_lib(libs, seen, path, roots)
  end

  table.sort(libs)
  return libs
end

--- Push the current library list to one client, only if it changed.
---@param client vim.lsp.Client
local function sync(client)
  local libs = client_libraries(client)
  if #libs == 0 then
    return
  end
  local key = table.concat(libs, "\0")
  if pushed[client.id] == key then
    return
  end
  pushed[client.id] = key

  if type(client.settings) ~= "table" then
    client.settings = {}
  end
  local settings = client.settings
  if type(settings.emmylua) ~= "table" then
    settings.emmylua = {}
  end
  if type(settings.emmylua.workspace) ~= "table" then
    settings.emmylua.workspace = {}
  end
  settings.emmylua.workspace.library = libs

  client:notify("workspace/didChangeConfiguration", {
    settings = { emmylua = settings.emmylua },
  })
end

--- Push the current library lists to every attached emmylua_ls client.
function M.sync_all()
  for _, client in ipairs(vim.lsp.get_clients({ name = "emmylua_ls" })) do
    sync(client)
  end
end

local timer = assert(vim.uv.new_timer())
local scheduled = false

local function schedule_sync()
  if scheduled then
    return
  end
  scheduled = true
  timer:stop()
  timer:start(
    100,
    0,
    vim.schedule_wrap(function()
      scheduled = false
      M.sync_all()
    end)
  )
end

local hooked = false

--- Re-sync whenever lazydev adds a library. lazydev exposes no event for this,
--- so hook its Workspace:add. Guarded by `hooked`; re-attempted from setup()
--- and LspAttach so it also works when lazydev loads after this plugin.
local function hook_lazydev()
  if hooked then
    return
  end
  local ok, Workspace = pcall(require, "lazydev.workspace")
  if not ok then
    return
  end
  hooked = true
  local orig_add = Workspace.add
  ---@param self lazydev.Workspace
  ---@param path string|string[]
  ---@diagnostic disable-next-line: duplicate-set-field, assign-type-mismatch, redundant-parameter
  Workspace.add = function(self, path)
    orig_add(self, path)
    schedule_sync()
  end
end

--- Record a library for all emmylua_ls clients attached to a buffer.
---@param buf integer
---@param lib string
---@return boolean added true when at least one client learned a new library
local function remember_lib(buf, lib)
  local added = false
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "emmylua_ls" })) do
    local libs = client_libs[client.id]
    if not libs then
      libs = {}
      client_libs[client.id] = libs
    end
    if not libs[lib] then
      libs[lib] = true
      added = true
    end
  end
  return added
end

--- Scan lines of a buffer for doc type roots and resolve their owning plugins.
---@param buf integer
---@param first integer
---@param last integer
function M.scan_buffer(buf, first, last)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end

  local mods = {}
  local seen = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, last, false)) do
    for _, mod in ipairs(scan_line(line)) do
      if not seen[mod] then
        seen[mod] = true
        mods[#mods + 1] = mod
      end
    end
  end
  local changed = false
  for _, mod in ipairs(mods) do
    local lib = resolve_lib(mod)
    if lib and remember_lib(buf, lib) then
      changed = true
    end
  end
  if changed then
    schedule_sync()
  end
end

--- Attach to a buffer and scan its current contents.
---@param buf integer
local function attach(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not attached[buf] then
    attached[buf] = true
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function(_, b, _, first, _, new_last)
        vim.schedule(function()
          M.scan_buffer(b, first, new_last)
        end)
      end,
      on_reload = function(_, b)
        vim.schedule(function()
          M.scan_buffer(b, 0, -1)
        end)
      end,
      on_detach = function(_, b)
        attached[b] = nil
      end,
    })
  end
  -- Always scan: a restarted client attaches to an already-attached buffer and
  -- needs its own copy of the type libraries.
  M.scan_buffer(buf, 0, -1)
end

--- Re-scan attached buffers and attach buffers that already have an
--- emmylua_ls client. Useful when the bridge or lazydev loads after a client
--- has already attached.
function M.rescan_all()
  for buf in pairs(attached) do
    if vim.api.nvim_buf_is_valid(buf) then
      M.scan_buffer(buf, 0, -1)
    else
      attached[buf] = nil
    end
  end
  for _, client in ipairs(vim.lsp.get_clients({ name = "emmylua_ls" })) do
    for buf in pairs(client.attached_buffers or {}) do
      attach(buf)
    end
  end
end

--- Seed a client config with libraries referenced by the current buffer.
--- Called from `after/lsp/emmylua_ls.lua` before the client starts, so the
--- first `didOpen` analysis already has the referenced plugins.
---@param settings table<string, any>
function M.seed(settings)
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local libs = {}
  local seen = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for _, mod in ipairs(scan_line(line)) do
      local lib = resolve_lib(mod)
      if lib and not seen[lib] then
        seen[lib] = true
        libs[#libs + 1] = lib
      end
    end
  end
  if #libs == 0 then
    return
  end

  if type(settings.emmylua) ~= "table" then
    settings.emmylua = {}
  end
  if type(settings.emmylua.workspace) ~= "table" then
    settings.emmylua.workspace = {}
  end
  local current = settings.emmylua.workspace.library
  if type(current) ~= "table" then
    current = {}
    settings.emmylua.workspace.library = current
  end
  for _, lib in ipairs(libs) do
    if not vim.tbl_contains(current, lib) then
      current[#current + 1] = lib
    end
  end
  table.sort(current)
end

--- Libraries that would be pushed to a client (used by :checkhealth).
---@param client? vim.lsp.Client
---@return string[]
function M.libraries(client)
  if client then
    return client_libraries(client)
  end
  local libs = {}
  local seen = {}
  for _, c in ipairs(vim.lsp.get_clients({ name = "emmylua_ls" })) do
    for _, lib in ipairs(client_libraries(c)) do
      if not seen[lib] then
        seen[lib] = true
        libs[#libs + 1] = lib
      end
    end
  end
  return libs
end

local did_setup = false

--- Register autocmds. Idempotent; called from after/lsp/emmylua_ls.lua.
function M.setup()
  if did_setup then
    return
  end
  did_setup = true

  local group = vim.api.nvim_create_augroup("emmylua_ls_bridge", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client or client.name ~= "emmylua_ls" then
        return
      end
      hook_lazydev()
      attach(ev.buf)
      schedule_sync()
    end,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      -- LspDetach is per buffer. Only forget the client when it has no buffers
      -- left; otherwise its libraries are still valid for the other buffers.
      if not client or next(client.attached_buffers or {}) == nil then
        pushed[ev.data.client_id] = nil
        client_libs[ev.data.client_id] = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      attached[ev.buf] = nil
    end,
  })
  -- Safety nets for lazydev loading after us (it emits no "loaded" event).
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VeryLazy",
    once = true,
    callback = function()
      hook_lazydev()
      M.rescan_all()
      schedule_sync()
    end,
  })
  vim.schedule(function()
    hook_lazydev()
    M.rescan_all()
    schedule_sync()
  end)

  -- The plugin may have been loaded after emmylua_ls already attached.
  hook_lazydev()
  schedule_sync()
end

return M
