# emmylua_ls_bridge.nvim

Bridge [lazydev.nvim](https://github.com/folke/lazydev.nvim)'s dynamic workspace
libraries into [emmylua_ls](https://github.com/EmmyLuaLs/emmylua-analyzer-rust).

## Why

`emmylua_ls` has no glob support for `workspace.library`, so plugin libraries
must be added dynamically. `lazydev.nvim` already does the hard part: it watches
Lua buffers for `require()` / `---@module "x"` and resolves each reference to the
owning plugin.

For Neovim clients, stock `emmylua_ls` fetches both the `Lua` and `emmylua`
client config scopes and keeps only the **last non-empty** one. As soon as any
tool sets `emmylua` settings (this plugin sets `emmylua.codeLens` /
`emmylua.hint`, for example), the `Lua.workspace.library` list that lazydev
publishes is discarded. This plugin republishes the effective library list as
`emmylua.workspace.library`, which is the scope stock `emmylua_ls` actually uses
when `emmylua` is present.

A patched server merges the two scopes instead. The bridge still works there
(duplicates are deduplicated by the config merger), and its `---@type`
discovery remains useful.

It also adds `---@type` family discovery on top of lazydev. lazydev only scans
`require()` / `---@module`, so a dotted type reference like `zpack.Spec` did not
load `zpack.nvim` on its own. The bridge scans doc comments for dotted roots and
resolves them with lazydev's package resolver, so this works without an extra
`@module`:

```lua
---@type zpack.Spec
local spec = {
  "mikesmithgh/kitty-scrollback.nvim",
}
return spec
```

Because `zpack.Spec` carries the module root `zpack`, no per-file or per-type
declaration is needed. Undotted types (`LazySpec`, `MySpec`) still need a
`---@module` fallback or a static library, because their module cannot be
inferred from the name.

Static libraries (e.g. Neovim stubs, `$VIMRUNTIME/lua`, vendored deps) still
belong in your `.emmyrc.json`; this plugin only handles the dynamic, per-buffer
part.

> This is a compatibility layer. If `emmylua_ls` merges the `Lua` and `emmylua`
> scopes, and lazydev upstream learns to discover doc type references, the
> bridge can be retired.

## Requirements

- Neovim 0.11+ (`vim.lsp.config` / `vim.lsp.enable`)
- [lazydev.nvim](https://github.com/folke/lazydev.nvim) -- hard dependency for
  workspace discovery and module resolution
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

Use the dotted type directly:

```lua
---@type zpack.Spec
local spec = {
  "mikesmithgh/kitty-scrollback.nvim",
}
return spec
```

`zpack.nvim` enters the workspace library once a buffer references it. Nothing
is indexed up front.

For an undotted type, keep a module hint:

```lua
---@module "lazy"
---@type LazySpec
local spec = { ... }
return spec
```

## How it works

1. `after/lsp/emmylua_ls.lua` runs while Neovim resolves the `emmylua_ls` config
   from `runtimepath` (before the client starts). It requires lazydev, calls
   `require("emmylua_ls_bridge").setup()`, and seeds the current buffer's
   referenced libraries into the server settings.
2. `setup()` registers `LspAttach` / `LspDetach` handlers and hooks lazydev's
   `Workspace:add`.
3. On attach, and on every buffer change, the bridge scans `---@...` doc lines
   for dotted roots and resolves each root with lazydev's package resolver
   (`lazydev.pkg`). The resolved plugin root is recorded for **that client**.
4. lazydev still handles `require()` / `---@module` references through its own
   workspaces. The bridge hooks lazydev's `Workspace:add` and mirrors those
   libraries as well, filters out workspace-internal paths, and pushes the
   per-client list to `emmylua.workspace.library` with a small debounce.
5. `workspace/didChangeConfiguration` makes `emmylua_ls` re-read its config, so
   the referenced plugin is indexed and the types resolve.

Because it also runs on `LspAttach`, `VeryLazy` and a scheduled setup pass, it
keeps working when the plugin (or lazydev) loads after a client has already
attached.

## Health

```text
:checkhealth emmylua_ls_bridge
```

Reports whether lazydev is loaded, whether the bridge module loaded early enough,
and the library list currently pushed to each client.

## License

MIT
