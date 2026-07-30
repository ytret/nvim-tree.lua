# nvim-tree.lua — Architecture Guide for AI Agents

## Overview

nvim-tree is a Neovim file explorer plugin (sidebar tree). It scans a directory, builds an in-memory Node tree, and renders it as lines in a scratch buffer. It handles git status, LSP diagnostics, file watching, bookmarks, filtering, and all file operations.

**Tech**: Pure Lua, requires Neovim >= 0.10. Uses the [rxi/classic](https://github.com/rxi/classic) OOP library (augmented with `is`/`as`/`implement`).

---

## Module Map / Layers

```
┌───────────────────────────────────────────────────────┐
│ plugin/nvim-tree.lua    → calls commands.setup()      │  Entry point
├───────────────────────────────────────────────────────┤
│ lua/nvim-tree.lua       → M.setup()                   │  Public setup()
├───────────────────────────────────────────────────────┤
│ config.lua              → validate, merge, store as   │
│                           config.g (global mutable)   │  Configuration
├───────────────────────────────────────────────────────┤
│ core.lua                → singleton TreeExplorer      │  Core state
├───────────────────────────────────────────────────────┤
│ explorer/init.lua       → Explorer class              │
│   explorer/filters.lua  → dotfiles, git, custom, etc  │  Data/Model
│   explorer/sorter.lua   → node sorting                │
│   explorer/live-filter.lua → interactive filtering    │
│   explorer/watch.lua    → per-directory watchers      │
├───────────────────────────────────────────────────────┤
│ node/init.lua           → Node (abstract base)        │
│ node/directory.lua      → DirectoryNode               │  Node tree
│ node/file.lua           → FileNode                    │  (inheritance)
│ node/link.lua           → LinkNode (mixin)            │
│ node/root.lua           → RootNode                    │
│ node/factory.lua        → creates appropriate Node    │
├───────────────────────────────────────────────────────┤
│ view.lua                → window/buffer management    │  View
│ view-state.lua          → per-tab cursor, width       │
├───────────────────────────────────────────────────────┤
│ renderer/init.lua       → Renderer:draw()             │
│ renderer/builder.lua    → Node tree → lines/hl/signs  │  Rendering
│ renderer/components/    → icons, padding, full-name   │
│ renderer/decorator/     → pluggable icon/hl decorators│
├───────────────────────────────────────────────────────┤
│ git/init.lua            → git status, project mgmt    │  Git
│ git/runner.lua          → async git command runner    │
├───────────────────────────────────────────────────────┤
│ diagnostics.lua         → LSP + COC diagnostics       │  Diagnostics
├───────────────────────────────────────────────────────┤
│ watcher.lua             → Event + Watcher classes     │
│                         → uv fs_event wrappers        │  File watching
├───────────────────────────────────────────────────────┤
│ marks/init.lua          → bookmarks                   │  Bookmarks
├───────────────────────────────────────────────────────┤
│ actions/                → user-facing operations      │
│   node/open-file.lua    → open, split, tab, preview   │
│   node/run-command.lua  → run command on node         │
│   fs/                   → create, delete, rename,     │  Actions
│       clipboard, trash                                │
│   moves/                → cursor navigation           │
│   tree/                 → open, close, change-dir,    │
│       collapse, resize, find-file                     │
│   finders/              → find-file, search-node      │
├───────────────────────────────────────────────────────┤
│ api.lua                 → public stable API           │
│ api/impl.lua            → hydration (pre/post setup)  │  Public API
│ _meta/api/              → typed API stubs             │
│ _meta/config/           → per-section config defaults │
│ _meta/classes.lua       → type definitions            │
├───────────────────────────────────────────────────────┤
│ events.lua              → pub/sub event dispatch      │
│ autocmd.lua             → global autocmds             │  Infrastructure
│ commands.lua            → user commands (:NvimTree*)  │
│ keymap.lua              → default keymaps             │
│ legacy.lua              → config migration            │
│ utils.lua               → shared utilities            │
│ classic.lua             → OOP framework               │
│ lib.lua                 → open/buffer hijack logic    │
│ session.lua             → session restore             │
│ buffers.lua             → buffer modified/open state  │
│ notify.lua              → user notifications          │
│ log.lua                 → diagnostic logging          │
│ enum.lua                → shared enums (FILTER_REASON)│
└───────────────────────────────────────────────────────┘
```

---

## Key Data Structures

### Node Hierarchy (classic.lua OOP)

```
Node (abstract base)
├── FileNode
├── DirectoryNode
│   └── RootNode
│       └── Explorer  ← IS a RootNode!
├── LinkNode (mixin)
    ├── FileLinkNode (FileNode + LinkNode)
    └── DirectoryLinkNode (DirectoryNode + LinkNode)
```

**Key fields on Node:**
- `uid_node` — unique ID (hrtime)
- `absolute_path`, `name`, `type` ("file"/"directory"/"link")
- `parent` — parent DirectoryNode (nil for root)
- `executable`, `fs_stat`, `git_status`, `diag_status`, `hidden`

**Key fields on DirectoryNode:**
- `nodes` — `Node[]` children
- `open` — expanded state
- `group_next` — `DirectoryNode?` — if grouped, points to the next child in a chain of empty single-child dirs. The last node has `group_next = nil`. This is the "group empty folders" feature.
- `hidden_stats` — counts per FILTER_REASON

**Explorer IS-A RootNode IS-A DirectoryNode.** This means the explorer object IS the root of the tree. It additionally owns: `renderer`, `filters`, `sorters`, `marks`, `clipboard`, `live_filter`, `augroup_id`, `uid_explorer`.

### config.g

A global mutable table set by `config.setup()`. It's the merged user + default config. Read *everywhere*. Never nil after setup. Key sections: `renderer`, `view`, `git`, `diagnostics`, `filters`, `actions`, `filesystem_watchers`, etc.

### config.d / config.u / config.os

- `config.d` — immutable defaults, localized once for OS
- `config.u` — deep copy of user config (for reference)
- `config.os` — `{ unix, macos, wsl, windows }` booleans

### view_state.Active

Global mutable state for window options, width, adaptive size, per-tab cursors, and per-tab winnrs.

---

## Flow of a Typical Operation

### 1. Plugin loads → setup

```
plugin/nvim-tree.lua
  → commands.setup()          -- create :NvimTree* user commands
lua/nvim-tree.lua (M.setup)
  → config.setup(user_config) -- validate, migrate legacy, store as config.g
  → log.start()
  → appearance.highlight()    -- define highlight groups
  → view_state.initialize()   -- apply view config to view_state.Active
  → autocmd.global()          -- BufWipeout, DirChanged, TabEnter, etc.
  → if re-setup: core.purge_all_state()
  → api_impl.hydrate_post_setup(api)
  → fire NvimTreeSetup event
```

### 2. Opening the tree

```
api.tree.open() → actions/tree/open.lua
  → core.init(path)           -- create Explorer (scans directory, builds node tree)
  → lib.open()                -- create buffer, open window, draw
    → view.open()             -- split window, set window options
    → explorer.renderer:draw()
```

### 3. core.init(path)

Creates a new `Explorer` (replaces any existing one). The Explorer constructor calls `RootNode:new()`, then `_load(self)`, which does:

```
_load → git.load_project(cwd) → explore(node, project, self)
  → populate_children: scandir, create nodes via node_factory.create()
  → (if group_empty) recursively merge single-child dirs via group_next
  → sorter:sort()
  → live_filter:apply_filter()
```

### 4. Rendering (Builder + Renderer)

```
Renderer:draw()
  → Builder(explorer):build()
    → build_header()         -- root folder label, live filter line
    → build_lines(root)      -- recursively walk visible nodes
      → build_signs(node)    -- signcolumn decorators
      → icon_name_decorated(node)  -- apply all decorators
      → build_line(node)     -- assemble indent, arrows, icon, name into line
      → build_lines(dir)     -- recurse into open directories
    → sanitize_lines()       -- strip newlines
  → _draw(bufnr, lines, hl_range_args, signs, extmarks)
    → vim.api.nvim_buf_set_lines
    → render_hl (vim.hl.range or batch nvim_buf_add_highlight)
    → sign_place
    → extmarks for right-aligned icons
    → virtual_lines for hidden count
  → view.grow_from_content() -- adaptive sizing
  → fire TreeRendered event
```

### 5. Opening a file from the tree

```
api.node.open.edit()
  → actions/node/open-file.lua
    → open_or_expand_or_dir_up(node, mode)
      If directory: dir:expand_or_collapse() → reload children, draw
      If file: edit(mode, node)
        → M.fn(mode, path)
          → get_target_winid() with window picker logic
          → open_in_new_window() or vim.cmd("edit")
          → optional quit_on_open, resize, focus
```

### 6. File system event → redraw

```
uv fs_event fires
  → explorer/watch.lua create_watcher callback (debounced)
  → git.refresh_dir(node)     -- re-read git status for the dir
    → explorer:reload(node, project)  -- re-scandir, merge children
    → explorer.renderer:draw()
```

---

## Decorator System

Decorators are how nvim-tree renders per-node icons, highlights, and signs. They follow a plugin architecture.

**Two flavors:**

| | `BuiltinDecorator` | User `Decorator` |
|---|---|---|
| Base class | `BuiltinDecorator` extends `Decorator` | `Decorator` |
| Node type | Internal `Node` | `nvim_tree.api.Node` (cloned) |
| Examples | Git, Open, Modified, Diagnostics, Bookmarks, Copied, Cut, Hidden | User-provided via `config.renderer.decorators` |

**Builtin decorators** are listed in `BUILTIN_DECORATORS` (builder.lua) and instantiated in the order specified by `config.renderer.decorators`. Each decorator has:
- `icon_node(node)` — override the icon
- `highlight_group_icon_name(node)` → `icon_hl, name_hl`
- `icons_before/after/right_align(node)` → highlighted_strings
- `sign_name(node)` → sign for signcolumn
- `icon_placement` — "before", "after", "signcolumn", "right_align"
- `highlight_range` — "none", "icon", "name", "all"

**The Builder** calls decorators in order. Later decorators can override the icon. Highlight groups are layered: if multiple decorators highlight the same element, a combined highlight group is created on-the-fly named `NvimTreeCombinedHL<sha256>`.

---

## Key Design Patterns & Conventions

### Classic OOP (`classic.lua`)

```lua
local Foo = Class:extend()
function Foo:new(args) ... end    -- constructor (self already allocated)
function Foo:destroy() ... end    -- destructor
local foo = Foo(args)             -- __call invokes new()
foo:is(Bar)                       -- instanceof
foo:as(Bar)                       -- safe cast (nil if not)
Foo:implement(Mixin)              -- mixin
```

### NodeIterator (`iterators/node-iterator.lua`)

Fluent builder for tree traversal:
```lua
Iterator.builder(nodes)
  :hidden()       -- include hidden nodes
  :matcher(fn)    -- find first matching node
  :applier(fn)    -- apply function to each node
  :recursor(fn)   -- how to traverse children (default: node.nodes)
  :iterate()      -- returns node, index
```

### Debounce (`utils.debounce`)

Context-based debouncing with timer management. A running callback will be rescheduled if the debouncer fires again during execution.

### Explorer owns everything

All sub-systems (filters, sorters, marks, clipboard, live_filter, renderer) are instantiated by the Explorer constructor and hold a reference back to the explorer.

---

## Oddities & Compromises

### 1. Explorer IS a RootNode

This is the biggest architectural oddity. `Explorer` extends `RootNode` extends `DirectoryNode` extends `Node`. The Explorer object is both:
- The root of the file tree model (has children `nodes`, can be traversed)
- The controller/owner of all subsystems (renderer, filters, etc.)

This means the tree model and the controller are the same object. It works but can cause confusion — e.g., when `core.init()` destroys an old Explorer, all subsystems are destroyed too. The pattern `local explorer = core.get_explorer()` is used defensively after `core.init()` because `init` replaces the global singleton.

### 2. Two Node APIs (Internal vs Public)

- **Internal**: `Node`, `FileNode`, `DirectoryNode`, etc. — used throughout the plugin. Has methods like `:expand()`, `:is_dotfile()`, `:is_git_ignored()`.
- **Public**: `nvim_tree.api.Node`, `nvim_tree.api.DirectoryNode` — a sanitized clone created by `Node:clone()`. No methods, just data. Used by user decorators and the public API.

The Builder handles both: builtin decorators get the internal Node directly, user decorators get the public API clone (created once, cached as `self.api_nodes`).

### 3. Global Mutable State

- `config.g` — global config, read everywhere
- `core.TreeExplorer` — module-local singleton
- `view_state.Active` — global mutable state (widths, cursors, tabpages)
- `view.BUFNR_PER_TAB` — module-local table of buffer numbers per tab
- `git._projects_by_toplevel`, `git._toplevels_by_path` — git state caches

This is typical for Neovim plugins (Lua modules are effectively singletons). The pattern to reset state is `core.purge_all_state()` which destroys the explorer, closes all windows, and purges watchers.

### 4. group_empty / group_next

When `renderer.group_empty = true`, consecutive directories that have exactly one child are "grouped" into a visual path like `a/b/c/`. This is implemented as a linked list: `DirectoryNode.group_next` points to the one child, and `group_next` of the last node is nil. This complicates traversal — code often calls `node:get_parent_of_group()` or `node:last_group_node()` to normalize. The grouped nodes are still individual DirectoryNode objects; the rendering just concatenates their names and skips drawing intermediate levels.

### 5. Config Validation is Inline

`config.lua` contains a recursive type-and-value validator with three parallel nested tables: `ACCEPTED_TYPES`, `ACCEPTED_STRINGS`, `ACCEPTED_ENUMS`. These shadow the structure of `config.d`. The validator walks user config and default config in lockstep, warning and removing invalid fields. It's verbose but self-contained.

### 5b. Default Config is Delimited by Comments

`config.d` has `-- config-default-start` and `-- config-default-end` markers. These are used by `scripts/` to auto-generate help docs. Don't change these markers.

### 6. Legacy Config Migration

`legacy.lua` contains `migrate_config(u)` which mutates user config in place. It handles:
- Renamed fields (e.g., `update_cwd` → `sync_root_with_cwd`)
- Type changes (e.g., `highlight_git` boolean → "name"/"none")
- Moved fields (e.g., `sort_by` → `sort.sorter`)

Also maps deprecated API paths to current ones in `map_api`.

### 7. File System Watchers Are Two-Tier

- `watcher.lua`: `Event` class wraps a single `uv.fs_event` for a path. `Watcher` class wraps an Event with file filtering and a callback. The Watcher holds user data and tracks `destroyed` state.
- `explorer/watch.lua`: Creates Watchers per `DirectoryNode`. Callback is debounced per-path and triggers `git.refresh_dir()` which reloads the directory and redraws.

Git also creates its own Watcher on `.git` directory to watch for ref/staging changes.

### 8. Window Picker

The built-in window picker (`actions.node.open-file.pick_win_id`) temporarily replaces statuslines with character labels (A, B, C...) and waits for a keypress. It saves and restores all original statusline and winhl options. This is a clever but fragile UI pattern.

### 9. _prevent_buffer_override

When a user opens a file with `:e` in the tree window, Nvim replaces the tree buffer. `view._prevent_buffer_override()` handles this by:
1. Scheduling a callback on BufWipeout
2. Letting the new buffer populate the window
3. Re-opening the tree in a new split, drawing it, closing the old window
4. Opening the file in the target window

This is hairy but necessary.

### 10. Adaptive Sizing

When `config.view.width` is a table (with `min`, `max`, `lines_excluded`, `padding`), the tree width adapts to content. `view.grow_from_content()` scans all rendered lines + extmarks and resizes the window if wider than current. This runs on every draw.

### 11. Live Filter

The live filter (`explorer/live-filter.lua`) is separate from the regular filters. It's an interactive search that shows a prompt in the tree buffer. When active, a filter line appears above the tree, and nodes are hidden/shown as the user types. The filter line is rendered as part of `build_header()`.

### 12. Tab Sync

`tab.sync.open` and `tab.sync.close` control whether opening/closing the tree in one tab affects all tabs. Each tab has its own buffer (`NvimTree_<tabnr>`) but shares the same Explorer (data). This can lead to stale renders — you need to call `explorer.renderer:draw()` after switching tabs.

### 13. Pre/Post Setup API Hydration

`api/impl.lua` has two phases:
- `hydrate_pre_setup` — fills API entries that don't need config/setup state (called on module require)
- `hydrate_post_setup` — fills API entries that need the explorer/config to be available (called after setup, and also every re-setup)

### 14. `NvimTreeRequired` vs `NvimTreeSetup` events

- `NvimTreeRequired` — fires on first `require("nvim-tree")` (module load, before setup)
- `NvimTreeSetup` — fires after `M.setup()` completes (and on every re-setup)

### 15. COC + Native LSP Diagnostics

Diagnostics module supports both native Neovim LSP (`DiagnosticChanged` autocmd) and COC (`CocDiagnosticChange` User event). They use different APIs to fetch diagnostics but converge on the same `NODE_SEVERITIES` cache.

---

## Testing / Debugging

- Logging: `config.log.enable = true` with `types.dev = true` for verbose tracing. Logs go to `vim.fn.stdpath("data")/nvim-tree.log`.
- Profile: `log.profile_start("label")` / `log.profile_end(profile)` wraps operations with timing.
- HiTest: `:NvimTreeHiTest` or `api.appearance.hi_test()` renders a sample of all highlight groups.
- `nvim-tree/api.lua` is the only supported public interface. Internal modules may change without notice.

## File Operations Summary

| Action | File | Key Implementation |
|--------|------|-------------------|
| Open file | `actions/node/open-file.lua` | Window picker, multiple modes |
| Create file/dir | `actions/fs/create-file.lua` | vim.ui.input prompt |
| Delete | `actions/fs/remove-file.lua` | `vim.fn.delete`, optional confirm |
| Trash | `actions/fs/trash.lua` | OS-specific trash command |
| Rename | `actions/fs/rename-file.lua` | Full path, basename, or "rename sub" |
| Copy/Cut/Paste | `actions/fs/clipboard.lua` | OS clipboard, internal clipboard |
| Run command | `actions/node/run-command.lua` | Prompt for command, run on node |
| System open | `actions/node/system-open.lua` | `vim.ui.open()` |
| CD / Change root | `actions/tree/change-dir.lua`, `change-root.lua` | Updates explorer cwd |

---

## Where to Start for Common Tasks

- **Bug: rendering issue** → `renderer/builder.lua` (line building), then the specific decorator in `renderer/decorator/`
- **Bug: file operation** → `actions/` directory, then check `utils.lua` for path helpers
- **Bug: tree not updating** → `explorer/init.lua` (`reload`, `reload_explorer`), `explorer/watch.lua`, `watcher.lua`
- **Bug: git status wrong** → `git/init.lua` (`reload_project`), `git/runner.lua`
- **Adding a config option** → `lua/nvim-tree/_meta/config/<section>.lua` for the type definition, `config.lua` for the default (`config.d`), then use `config.g.<path>` in the implementation
- **Adding a new decorator** → Copy pattern from `renderer/decorator/git.lua`, register in `BUILTIN_DECORATORS` in `builder.lua`
- **Adding a new action** → `actions/` directory, wire up via `api/impl.lua` and `_meta/api/`, add default keymap in `keymap.lua`
- **Config validation** → `config.lua`: update `config.d`, `ACCEPTED_TYPES`, `ACCEPTED_STRINGS`, `ACCEPTED_ENUMS`
