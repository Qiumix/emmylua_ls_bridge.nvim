# emmylua_ls_bridge.nvim

Bridge [lazydev.nvim](https://github.com/folke/lazydev.nvim)'s dynamic workspace
libraries into [emmylua_ls](https://github.com/EmmyLuaLs/emmylua-analyzer-rust).

## Why

`emmylua_ls` reads `workspace.library` statically and has no glob support, and
`lazydev.nvim` emits LuaLS-shaped settings (`Lua.workspace.library`) that
`emmylua_ls` ignores. So with `emmylua_ls` you lose the "plugin types show up
after you `require()` them" experience you get from `lua_ls` + lazydev.

This plugin re-publishes lazydev's library list as `emmylua.workspace.library` --
the only scope `emmylua_ls` honours for Neovim clients. lazydev already does the
discovery (it watches buffers for `require()` / `---@module "x"` and resolves each
reference to the owning plugin), so plugins are only indexed once a buffer
actually references them.

And because `emmylua_ls` indexes libraries almost instantaneously, those on-demand
updates are effectively free: you get the whole lazydev workflow with sub-second
type resolution -- in practice a noticeably better experience than `lua_ls`.

Static libraries (e.g. Neovim `vim.*` stubs, `$VIMRUNTIME`, vendored deps) still
belong in your `.emmyrc.json`; this plugin only handles the dynamic, per-buffer
part.

## Requirements

- Neovim 0.11+ (`vim.lsp.config` / `vim.lsp.enable`)
- [lazydev.nvim](https://github.com/folke/lazydev.nvim) -- hard dependency; the
  bridge logs an error if it is missing
- `emmylua_ls` available in `$PATH`

## Installation

The plugin ships its own `after/lsp/emmylua_ls.lua`, and Neovim only reads
`lsp/<name>.lua` from `runtimepath` **while resolving the server config**. So the
plugin must already be loaded **before** you call `vim.lsp.enable("emmylua_ls")` --
otherwise the file is never read and the bridge silently does nothing.

**load the plugin first, enable the server last.**

### lazy.nvim

Declaring lazydev as a `dependencies` entry makes lazy.nvim load it before the
bridge. Any lazy trigger is fine, the ordering is what matters:

```lua
{
  "qiumix/emmylua_ls_bridge.nvim",
  dependencies = { "folke/lazydev.nvim" },
  ft = "lua",
}

vim.lsp.enable("emmylua_ls") -- after the plugin has loaded
```

### vim.pack

`vim.pack` has no dependency resolution, so load lazydev yourself first and
enable the server last:

```lua
vim.pack.add({
  { src = "https://github.com/folke/lazydev.nvim" },
  { src = "https://github.com/qiumix/emmylua_ls_bridge.nvim" },
})

require("lazydev").setup() -- 1. lazydev first
require("emmylua_ls_bridge").setup() -- 2. then the bridge

vim.lsp.enable("emmylua_ls") -- 3. enable after both are loaded
```

## Usage

Annotate the module first with `---@module`, then use its types with `---@type`.
lazydev picks the annotation up, adds the owning plugin to the workspace
libraries, and `emmylua_ls` resolves the types:

```lua
---@module "which-key"
---@type wk.Spec
local keys = {
  { "<leader>f", group = "find" },
}
```

`which-key.nvim` only enters the workspace library once a buffer references it --
nothing is indexed up front, and the types are available right after.

## How it works

1. `after/lsp/emmylua_ls.lua` runs while Neovim resolves the `emmylua_ls` config
   from `runtimepath` (before the client starts). It requires lazydev, calls
   `require("emmylua_ls_bridge").setup()`, and returns the server config.
2. `setup()` registers an `LspAttach` handler and hooks lazydev's `Workspace:add`.
3. Whenever lazydev discovers a library for a buffer, the bridge pushes the
   accumulated list to every attached `emmylua_ls` client via
   `workspace/didChangeConfiguration`.

Because it also syncs on `LspAttach` and during `setup()`, it keeps working when
the plugin (or lazydev) loads after a client has already attached.

## Health

```text
:checkhealth emmylua_ls_bridge
```

Reports whether lazydev is loaded, whether the bridge module loaded early enough,
and the library list currently pushed to each client.

## License

MIT
