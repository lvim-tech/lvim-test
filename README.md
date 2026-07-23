# lvim-test

A native, granular test-runner framework for the lvim-tech ecosystem — run **this test / this
file / the whole suite** from inside Neovim and see per-test **pass / fail / skip** as they stream
in. Tests are discovered automatically from the project with treesitter, run through
[lvim-tasks](https://github.com/lvim-tech/lvim-tasks), and reported back per position.

`lvim-test` is a thin **engine** plus per-language **adapters**. An adapter is (mostly) data:
which files are tests, a treesitter query that finds the individual tests, how to build the run
command, and how to read the runner's output. The engine owns discovery, the run pipeline and the
results — it never knows what "go" or "dart" means.

Adapters shipped: **Go** (`go test -json`), **Dart / Flutter** (`flutter test --machine` /
`dart test --reporter=json`), **Rust** (`cargo test`), **Python** (`pytest -v`), **TypeScript /
JavaScript** (`vitest` / `jest`, across `typescript` / `typescriptreact` / `javascript` /
`javascriptreact`), **C / C++** (GoogleTest + Catch2 via CTest), **Java** (JUnit via gradle / maven,
surefire XML), **C# / .NET** (`dotnet test`, TRX report) and **Zig** (`zig test` / `zig build test`,
streamed `N/M test.name...OK|SKIP|FAIL`). External adapters self-register.

## Features

- **Automatic discovery** — the project is walked for test files (by name), and each file's tests
  are parsed **lazily** (only when opened, run, or expanded) with the ecosystem's own treesitter
  runtime ([lvim-ts](https://github.com/lvim-tech/lvim-ts)) — no up-front project crawl.
- **Run anything** — the nearest test at the cursor, the current file, or the whole project suite.
- **Summary sidebar** — a docked tree of the whole project (files → namespaces → tests) with live
  per-test status icons and per-file aggregate counts; run / output / mark / re-run-failed and
  more straight from the tree (`:LvimTest summary`).
- **Colored feedback** — gutter status signs (a spinner while running) + inline failure
  diagnostics at the assertion line, on the test's own source.
- **Watch mode** — `:LvimTest watch` (or `w` in the tree) re-runs a test on every save (debounced,
  file/project scoped), as a throwaway run that never clutters the task panel or history.
- **Streaming results** — statuses flip live while the run is still going (Go's `-json`, Dart's
  package:test JSON), landing in a store that any consumer reads through one `User` event.
- **Runs through lvim-tasks** — the test process is a task: full output in its terminal buffer,
  stop / restart, and the problem-matcher → quickfix, all inherited.
- **Statusline segment** — `require("lvim-test").status()` gives an aggregate for the current root.
- **Optional lvim-lang toolchain** — when a Dart provider is active, the `flutter`/`dart` binary is
  resolved through lvim-lang (FVM / explicit SDK); otherwise PATH. lvim-test works without it.

## Requirements

- Neovim >= 0.11
- [lvim-tasks](https://github.com/lvim-tech/lvim-tasks) — the execution backend (required)
- [lvim-ui](https://github.com/lvim-tech/lvim-ui) — windows (required)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) — palette / merge / store / cursor (required)
- [lvim-ts](https://github.com/lvim-tech/lvim-ts) — treesitter parsers for discovery (required)
- Optional: [lvim-dap](https://github.com/lvim-tech/lvim-dap) (debug a test),
  [lvim-lang](https://github.com/lvim-tech/lvim-lang) (toolchain resolution)

## Install

Install and manage it from the ecosystem's **lvim-installer** (open the Plugins tab), or with
Neovim's native `vim.pack`:

```lua
vim.pack.add({ "https://github.com/lvim-tech/lvim-test" })
require("lvim-test").setup({})
```

## Commands

`:LvimTest <sub>` — with no subcommand, runs the nearest test.

| Command | Description |
| --- | --- |
| `:LvimTest run [-- <args>]` | Run the nearest test (extra runner args after `--`) |
| `:LvimTest file [-- <args>]` | Run every test in the current file |
| `:LvimTest suite` | Run the whole project suite (every discovered test under the root) |
| `:LvimTest watch [stop]` | Toggle watch on the nearest test (re-run on save); `stop` = stop all |
| `:LvimTest last` | Replay the last run in this project |
| `:LvimTest failed` | Re-run every currently-failed test |
| `:LvimTest debug` | Debug the nearest test through lvim-dap (its exit code becomes the result) |
| `:LvimTest output [short]` | Show the nearest test's output (`short` = the one-line summary) |
| `:LvimTest jump next\|prev [failed]` | Jump to the next/previous test (optionally only failed) |
| `:LvimTest summary` | Toggle the summary sidebar (a docked tree of the project's tests) |
| `:LvimTest stop` | Stop the live run |
| `:LvimTest attach` | Focus the live run's terminal output (the lvim-tasks panel) |
| `:LvimTest clear` | Clear results / diagnostics / signs for the project |
| `:LvimTest refresh` | Drop discovery caches and re-parse open test files |

## Configuration

`setup()` merges your options into the live config in place; **everything is overridable** (your
`setup()` values always win). The complete default configuration:

```lua
require("lvim-test").setup({
    -- Built-in adapters to load (each self-registers). External adapters register themselves via
    -- require("lvim-test").register(); per-adapter options live under the matching key.
    adapters = {
        enabled = { "go", "dart", "rust", "python", "typescript", "cpp", "java", "csharp" },
        go = {
            args = {}, -- extra `go test` args on every run
            env = {},
            tags = nil, -- -tags value (nil = none)
        },
        dart = {
            args = {}, -- extra `flutter test` / `dart test` args
            env = {},
        },
        rust = {
            cargo_args = {}, -- extra `cargo test` args (before `--`)
            env = {},
            features = nil, -- `--features` value (nil = none)
        },
        python = {
            args = {}, -- extra `pytest` args on every run
            env = {},
        },
        typescript = {
            args = {}, -- extra vitest / jest args on every run
            env = {},
            runner = nil, -- force "vitest" | "jest" (nil = auto-detect)
        },
        cpp = {
            build_dir = "build", -- CMake build dir (ctest --test-dir)
            ctest_args = {},
            ctest_path = nil, -- explicit ctest binary (nil = PATH)
            env = {},
        },
        java = {
            args = {}, -- extra `gradle test` / `mvn test` args
            env = {},
        },
        csharp = {
            args = {}, -- extra `dotnet test` args
            env = {},
        },
    },

    -- The project WALK that lists candidate test files (parsing is separate + lazy).
    discovery = {
        ignore_dirs = { ".git", "node_modules", "target", "build", "dist", ".venv", "__pycache__" },
        max_files = 5000,
    },

    -- The run pipeline (every test process goes through lvim-tasks).
    run = {
        save = "current", -- write before running: "current" | "all" | false
        concurrent = false, -- allow parallel runs across different roots
        on_busy = "queue", -- a second request while running: "queue" | "replace" | "reject"
        missing_result = "skipped", -- status for ran-but-unreported positions
        open_panel = true, -- reveal the lvim-tasks panel (live output) when a run starts
        env = {}, -- extra env for every test process
    },

    -- Persistence through lvim-utils.store (json): last run, marks, last statuses per root.
    persist = {
        enabled = true,
        statuses = true,
    },

    -- Project-local overrides under the unified ".lvim" namespace
    -- (<root>/.lvim/test/config.lua returns a pure-data table merged over these defaults).
    project = {
        dir = ".lvim",
        file = "test/config.lua",
    },

    -- The summary sidebar (a persistent docked tree).
    summary = {
        side = "right", -- "right" | "left"
        width = 44,
        follow = true, -- tree cursor follows the editing position
        counts = true, -- aggregate pass/fail counts on dir/file rows
        expand_failed = true, -- auto-expand ancestors of failures after a run
        keys = { -- every key remappable; false disables one
            run = "r",
            debug = "d",
            stop = "s",
            output = "o",
            output_short = "O",
            attach = "a",
            mark = "m",
            run_marked = "R",
            clear_marks = "M",
            watch = "w",
            expand_all = "e",
            collapse_all = "c",
            jump_to = "i",
            next_failed = "J",
            prev_failed = "K",
            run_failed = "u",
            filter_failed = "f",
            clear = "x",
            help = "g?",
            close = "q",
        },
    },

    -- Output windows: a per-test output float and the full-run terminal (tasks panel).
    output = {
        open_on_fail = "short", -- after a failed run: "short" | "full" | false
        max_height = 0.6,
        max_width = 0.7,
    },

    -- Inline failure diagnostics (our own vim.diagnostic namespace).
    diagnostics = {
        enabled = true,
        severity = vim.diagnostic.severity.ERROR,
        virtual_text = true,
        underline = true,
    },

    -- Gutter status signs + eol status + the statusline segment.
    status = {
        signs = true,
        virtual_text = false, -- eol status icon + short message on the test line
        fps = 8, -- spinner repaint rate (running rows)
        format = "{passed} {failed} {skipped}", -- statusline segment template
        hud_flash_ms = 3000, -- lvim-hud overlay flash after a run (0 = off)
    },

    -- Watch mode: re-run watched positions on save, scoped to the file or the project.
    watch = {
        debounce_ms = 300,
        scope = "project", -- "project" | "file"
    },

    -- Icons. Nerd Font, single-width — EXCEPT running_frames (the spinner), single-width braille.
    icons = {
        test = "󰙨",
        namespace = "󰅩",
        file = "󰈔",
        dir = "󰉋",
        passed = "󰗠",
        failed = "󰅙",
        skipped = "󰍴",
        running_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
        marked = "󰃀",
        watching = "󰈈",
        adapter = "󰙨",
        pointer = "➤",
    },
})
```

## Project-local configuration

A `<root>/.lvim/test/config.lua` file returns a pure-data table merged over your global config for
that project — for example per-project runner args or environment:

```lua
return {
    adapters = { go = { args = { "-race" } } },
    run = { env = { CI = "1" } },
}
```

## Writing an adapter

An adapter is a table registered with `require("lvim-test").register(adapter)` — any load order,
at runtime. The minimum: a name, filetypes, root markers, a cheap `is_test_file` name test, a
treesitter discovery `query` (capturing `@test.name`/`@test.definition` and, optionally,
`@namespace.name`/`@namespace.definition`), a `build` returning the argv, and a `parse` (or a
streaming `stream`) turning runner output into per-position `{ status, short?, output?, errors? }`.
See `lua/lvim-test/adapters/go.lua` for a complete, streaming example.

## Statusline

`require("lvim-test").status()` returns the current root's aggregate segment (per
`config.status.format`) — drop it into your statusline.

## Health

`:checkhealth lvim-test` reports the ecosystem dependencies, the registered adapters and each
adapter's tool + treesitter-parser availability.
