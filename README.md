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

Static libraries (e.g. Neovim `vim.*` stubs, `$VIMRUNTIME`, vendored deps) still
belong in your `.emmyrc.json`; this plugin only handles the dynamic, per-buffer
part.

## Requirements

- Neovim 0.11+ (`vim.lsp.config` / `vim.lsp.enable`)
- [lazydev.nvim](https://github.com/folke/lazydev.nvim) -- hard dependency; the
  bridge logs an error if it is missing
- `emmylua_ls` available in `$PATH`

## Installation

The plugin ships its own `after/lsp/emmylua_ls.lua`, so all a user needs is to
load the plugin and enable the server:

```lua
vim.lsp.enable("emmylua_ls")
```

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
