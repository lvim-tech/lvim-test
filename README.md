# lvim-test

A native, granular test-runner framework for the lvim-tech ecosystem — run **this test / this
file / the whole suite** from inside Neovim and see per-test **pass / fail / skip** as they stream
in. Tests are discovered automatically from the project with treesitter, run through
[lvim-tasks](https://github.com/lvim-tech/lvim-tasks), and reported back per position.

`lvim-test` is a thin **engine** plus per-language **adapters**. An adapter is (mostly) data:
which files are tests, a treesitter query that finds the individual tests, how to build the run
command, and how to read the runner's output. The engine owns discovery, the run pipeline and the
results — it never knows what "go" or "dart" means.

**52 adapters ship, all enabled by default.** They come in two granularities:

- **Per-test** (treesitter discovery, results per position): **Go** (`go test -json`),
  **Dart / Flutter** (`flutter test --machine` / `dart test --reporter=json`), **Rust**
  (`cargo test`), **Python** (`pytest -v`), **TypeScript / JavaScript** (`vitest` / `jest`, across
  `typescript` / `typescriptreact` / `javascript` / `javascriptreact`), **C / C++** (GoogleTest +
  Catch2 via CTest), **Java** (JUnit via gradle / maven, surefire XML), **C#** and **F#**
  (`dotnet test`, TRX report), **Kotlin**, **Scala** (`sbt` / `mill`), **Swift** (`swift test`),
  **PHP** (`phpunit`), **Ruby** (`rspec`), **Zig** (`zig test` / `zig build test`), **OCaml**
  (`dune runtest`), **Erlang** (`rebar3 eunit`), **Elixir** (`mix test`), **Haskell** (hspec),
  **Clojure**, **Julia** (`Pkg.test`), **R** (testthat).
- **File- / suite-granular** (no per-test query — every covered file takes the run's outcome):
  **Perl** (`prove`, per `.t` file), **D** (`dub test`), Crystal, Nim, Elm, V, Odin, Gleam, Racket,
  PureScript, Ada, Hare, Groovy, ReScript, Vala, Roc, Fish, Nushell, Grain, Common Lisp, Pascal,
  Terraform, Ansible (molecule), Fortran (fpm), Tcl, Solidity (forge), PowerShell (Pester), Move,
  Cairo (scarb), GDScript (GUT).

External adapters self-register.

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
- **Streaming results** — statuses flip live while the run is still going (Go, Dart, Rust, Python,
  Swift, Zig and CTest stream; the others report when the run ends), landing in a store that any
  consumer reads through one `User` event.
- **Runs through lvim-tasks** — the test process is a task: full output in its terminal buffer,
  stop / restart, and the problem-matcher → quickfix, all inherited.
- **Debug a test** — `:LvimTest debug` hands the nearest test to
  [lvim-dap](https://github.com/lvim-tech/lvim-dap) for Go, Dart, Python, TypeScript, Java,
  Kotlin, Scala, PHP, Ruby, Elixir and Haskell.
- **Statusline segment** — `require("lvim-test").status()` gives an aggregate for the current root.
- **Optional lvim-lang toolchain** — when a language provider is active, the runner binary is
  resolved through lvim-lang (FVM / explicit SDK); otherwise PATH. lvim-test works without it.

Results live in memory for the session: they are not persisted across restarts yet (the `persist`
config group is reserved for that).

## Requirements

- Neovim >= 0.12 (what lvim-ui and lvim-utils need)
- [lvim-tasks](https://github.com/lvim-tech/lvim-tasks) — the execution backend (required)
- [lvim-ui](https://github.com/lvim-tech/lvim-ui) — windows (required)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) — palette / merge / cursor (required)
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
`setup()` values always win). The complete default configuration (keys marked RESERVED exist for
forward compatibility and are not read by the current code):

```lua
require("lvim-test").setup({
    -- Built-in adapters to load (each self-registers). External adapters register themselves via
    -- require("lvim-test").register(); per-adapter options live under the matching key.
    adapters = {
        enabled = {
            "go", "dart", "rust", "python", "typescript", "cpp", "java", "csharp", "fsharp",
            "kotlin", "scala", "swift", "php", "ruby", "zig", "ocaml", "erlang", "elixir",
            "haskell", "clojure", "julia", "r", "perl", "d", "crystal", "nim", "elm", "v", "odin",
            "gleam", "racket", "purescript", "ada", "hare", "groovy", "rescript", "vala", "roc",
            "fish", "nushell", "grain", "commonlisp", "pascal", "terraform", "ansible", "fortran",
            "tcl", "solidity", "powershell", "move", "cairo", "gdscript",
        },
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
            build_dir = "build", -- CMake build dir (ctest --test-dir points here)
            ctest_args = {}, -- extra `ctest` args on every run
            ctest_path = nil, -- explicit ctest binary (nil = PATH)
            env = {},
        },
        java = {
            args = {}, -- extra `gradle test` / `mvn test` args on every run
            env = {},
        },
        csharp = {
            args = {}, -- extra `dotnet test` args on every run
            env = {},
        },
        fsharp = {
            args = {}, -- extra `dotnet test` args on every run
            env = {},
        },
        kotlin = {
            args = {}, -- extra `gradle test` / `mvn test` args on every run
            env = {},
        },
        scala = {
            args = {}, -- extra `sbt` / `mill` test args on every run
            env = {},
        },
        swift = {
            args = {}, -- extra `swift test` args on every run
            env = {},
        },
        php = {
            args = {}, -- extra `phpunit` args on every run
            env = {},
        },
        ruby = {
            args = {}, -- extra `rspec` args on every run
            env = {},
        },
        zig = {
            args = {}, -- extra `zig test` / `zig build test` args on every run
            env = {},
        },
        ocaml = {
            args = {}, -- extra `dune runtest` args on every run
            env = {},
        },
        erlang = {
            args = {}, -- extra `rebar3 eunit` args on every run
            env = {},
        },
        elixir = {
            args = {}, -- extra `mix test` args on every run
            env = {},
        },
        haskell = {
            args = {}, -- extra `stack test` / `cabal test` args on every run
            env = {},
        },
        clojure = {
            test_alias = "test", -- the deps.edn `:test` alias the Clojure CLI runs
            test_exec = true, -- Clojure CLI: `-X:test` exec runner (filters) vs `-M:test` main
            args = {}, -- extra test args on every run (after the tool's test verb)
            env = {},
        },
        julia = {
            project = ".", -- `--project` value for Pkg.test()
            args = {}, -- extra args on the julia test invocation
            env = {},
        },
        r = {
            args = {}, -- extra args on the Rscript testthat invocation
            env = {},
        },
        perl = {
            args = {}, -- extra `prove` args on every run
            env = {},
        },
        d = {
            args = {}, -- extra `dub test` args on every run
            env = {},
        },
        -- The suite-granular adapters share one shape: `args` are appended to the tool's test
        -- command, `env` is added to its environment.
        crystal = { args = {}, env = {} },
        nim = { args = {}, env = {} },
        elm = { args = {}, env = {} },
        v = { args = {}, env = {} },
        odin = { args = {}, env = {} },
        gleam = { args = {}, env = {} },
        racket = { args = {}, env = {} },
        purescript = { args = {}, env = {} },
        ada = { args = {}, env = {} },
        hare = { args = {}, env = {} },
        groovy = { args = {}, env = {} },
        rescript = { args = {}, env = {} },
        vala = { args = {}, env = {} },
        roc = { args = {}, env = {} },
        fish = { args = {}, env = {} },
        nushell = { args = {}, env = {} },
        grain = { args = {}, env = {} },
        commonlisp = { args = {}, env = {} },
        pascal = { args = {}, env = {} },
        terraform = { args = {}, env = {} },
        ansible = { args = {}, env = {} },
        fortran = { args = {}, env = {} },
        tcl = { args = {}, env = {} },
        solidity = { args = {}, env = {} },
        powershell = { args = {}, env = {} },
        move = { args = {}, env = {} },
        cairo = { args = {}, env = {} },
        gdscript = { args = {}, env = {} },
    },

    -- The project WALK that lists candidate test files (parsing is separate + lazy).
    discovery = {
        ignore_dirs = {
            ".git", "node_modules", "target", "build", ".build", "dist", ".venv", "__pycache__",
            "zig-out", ".zig-cache",
        },
        max_files = 5000,
    },

    -- The run pipeline (every test process goes through lvim-tasks).
    run = {
        save = "current", -- write before running: "current" | "all" | false
        concurrent = false, -- allow parallel runs across different roots
        -- A second request while a run is live: "replace" stops the live run first, "reject"
        -- refuses the new one; "queue" starts the new run at once (lvim-tasks keeps the old one's
        -- buffer) — true queueing is not implemented yet.
        on_busy = "queue",
        missing_result = "skipped", -- status for ran-but-unreported positions
        open_panel = true, -- reveal the lvim-tasks panel (live output) when a run starts
        env = {}, -- extra env for every test process
    },

    -- RESERVED — persistence through lvim-utils.store is not wired yet; results are per session.
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
        -- RESERVED — not read yet: the tree does not follow the cursor, the per-file counts are
        -- always shown, failures are not auto-expanded.
        follow = true,
        counts = true,
        expand_failed = true,
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
        -- RESERVED — not read yet: the float takes lvim-ui's default info-float size.
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
        hud_flash_ms = 3000, -- RESERVED — no lvim-hud flash is implemented yet
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
        file = "󰈔", -- fallback; real per-filetype glyphs come from lvim-utils.icons
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
`@namespace.name`/`@namespace.definition`) — or a custom `discover` — a `build` returning the
argv, and a `parse` (or a streaming `stream`) turning runner output into per-position
`{ status, short?, output?, errors? }`. An adapter without `query`/`discover` is suite-granular:
its test files are the positions and `parse` marks them from the run. See
`lua/lvim-test/adapters/go.lua` for a complete, streaming example and
`lua/lvim-test/adapters/crystal.lua` for the minimal suite-granular shape.

## Statusline

`require("lvim-test").status()` returns the current root's aggregate segment (per
`config.status.format`) — drop it into your statusline.

## Health

`:checkhealth lvim-test` reports the ecosystem dependencies, the registered adapters, each
adapter's tool + treesitter-parser availability and, when lvim-dap is installed, whether the DAP
adapter type each debug-capable adapter needs is registered.
