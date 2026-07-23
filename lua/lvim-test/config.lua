-- lvim-test.config: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it IN PLACE (through
-- lvim-utils.utils.merge), so every require("lvim-test.config") reader sees the effective
-- values without a restart. `config.adapters.<name>` is the per-language block an adapter
-- reads for its own options; the keys above it are shared by the engine + consumers.
--
-- This file is CONFIG only — nothing here is runtime state (the position tree, live results,
-- discovery caches all live in the engine modules).
--
---@module "lvim-test.config"

---@class LvimTestGoConfig
---@field args   string[]              Extra `go test` args appended on every run
---@field env    table<string,string>  Extra environment for the go test process
---@field tags?  string                `-tags` value (nil = none)

---@class LvimTestDartConfig
---@field args string[]              Extra `flutter test` / `dart test` args
---@field env  table<string,string>  Extra environment

---@class LvimTestRustConfig
---@field cargo_args string[]              Extra `cargo test` args (before `--`)
---@field env        table<string,string>  Extra environment for the cargo test process
---@field features?  string                `--features` value (nil = none)

---@class LvimTestPythonConfig
---@field args string[]              Extra `pytest` args appended on every run
---@field env  table<string,string>  Extra environment for the pytest process

---@class LvimTestTypescriptConfig
---@field args    string[]              Extra vitest / jest args appended on every run
---@field env     table<string,string>  Extra environment
---@field runner? string                Force the runner: "vitest" | "jest" (nil = auto-detect)

---@class LvimTestCppConfig
---@field build_dir  string                CMake build dir (ctest --test-dir)
---@field ctest_args string[]              Extra `ctest` args on every run
---@field ctest_path? string               Explicit ctest binary (nil = PATH)
---@field env        table<string,string>  Extra environment for the ctest process

---@class LvimTestJavaConfig
---@field args string[]              Extra `gradle test` / `mvn test` args appended on every run
---@field env  table<string,string>  Extra environment for the test process

---@class LvimTestCsharpConfig
---@field args string[]              Extra `dotnet test` args appended on every run
---@field env  table<string,string>  Extra environment for the dotnet test process

---@class LvimTestKotlinConfig
---@field args string[]              Extra `gradle test` / `mvn test` args appended on every run
---@field env  table<string,string>  Extra environment for the test process

---@class LvimTestSwiftConfig
---@field args string[]              Extra `swift test` args appended on every run
---@field env  table<string,string>  Extra environment for the swift test process

---@class LvimTestPhpConfig
---@field args string[]              Extra `phpunit` args appended on every run
---@field env  table<string,string>  Extra environment for the phpunit process

---@class LvimTestRubyConfig
---@field args string[]              Extra `rspec` args appended on every run
---@field env  table<string,string>  Extra environment for the rspec process

---@class LvimTestZigConfig
---@field args string[]              Extra `zig test` / `zig build test` args appended on every run
---@field env  table<string,string>  Extra environment for the zig test process

---@class LvimTestAdaptersConfig
---@field enabled    string[]           Built-in adapters to load (each self-registers)
---@field go         LvimTestGoConfig
---@field dart       LvimTestDartConfig
---@field rust       LvimTestRustConfig
---@field python     LvimTestPythonConfig
---@field typescript LvimTestTypescriptConfig
---@field cpp        LvimTestCppConfig
---@field java       LvimTestJavaConfig
---@field csharp     LvimTestCsharpConfig
---@field kotlin     LvimTestKotlinConfig
---@field swift      LvimTestSwiftConfig
---@field php        LvimTestPhpConfig
---@field ruby       LvimTestRubyConfig
---@field zig        LvimTestZigConfig

---@class LvimTestDiscoveryConfig
---@field ignore_dirs string[]         Directories pruned from the project walk
---@field max_files   integer          Project-walk cap (summary dir listing)

---@class LvimTestRunConfig
---@field save           string        Pre-run save: "current" | "all" | false
---@field concurrent     boolean       Allow parallel runs across different roots
---@field on_busy        string        Second request while running: "queue" | "replace" | "reject"
---@field missing_result string        Status for ran-but-unreported positions
---@field open_panel     boolean       Reveal the lvim-tasks panel (live output) when a run starts
---@field env            table<string,string>  Extra env for every test process

---@class LvimTestPersistConfig
---@field enabled  boolean             Persist last run + marks + last statuses per root
---@field statuses boolean             Restore last-run signs on fresh sessions

---@class LvimTestProjectConfig
---@field dir  string                  Project-local config dir (unified ".lvim" namespace)
---@field file string                  Config file, relative to `dir` (".lvim/test/config.lua")

---@class LvimTestSummaryConfig
---@field side          string         "right" | "left"
---@field width         integer        Sidebar width in columns
---@field follow        boolean        Tree cursor follows the editing position
---@field counts        boolean        Aggregate pass/fail counts on dir/file rows
---@field expand_failed boolean        Auto-expand ancestors of failures after a run
---@field keys          table<string,string|false>  Every summary keymap (false disables one)

---@class LvimTestOutputConfig
---@field open_on_fail string|false    After a failed run: "short" | "full" | false
---@field max_height   number          Info-float height cap (fraction or rows)
---@field max_width    number          Info-float width cap (fraction or rows)

---@class LvimTestDiagnosticsConfig
---@field enabled      boolean
---@field severity     integer         vim.diagnostic.severity value
---@field virtual_text boolean
---@field underline    boolean

---@class LvimTestStatusConfig
---@field signs        boolean         Gutter status signs on test rows
---@field virtual_text boolean         EOL status icon + short message on the test line
---@field fps          integer         Spinner repaint rate for running rows
---@field format       string          Statusline segment template
---@field hud_flash_ms integer         lvim-hud overlay flash after a run (0 = off)

---@class LvimTestWatchConfig
---@field debounce_ms integer          Debounce for re-runs after a save
---@field scope       string           "project" | "file"

---@class LvimTestIconsConfig
---@field test           string
---@field namespace      string
---@field file           string
---@field dir            string
---@field passed         string
---@field failed         string
---@field skipped        string
---@field running_frames string[]      Spinner frames for a running position (single-width braille)
---@field marked         string
---@field watching       string
---@field adapter        string
---@field pointer        string        Active-item pointer (canon: ➤)

---@class LvimTestConfig
---@field adapters    LvimTestAdaptersConfig
---@field discovery   LvimTestDiscoveryConfig
---@field run         LvimTestRunConfig
---@field persist     LvimTestPersistConfig
---@field project     LvimTestProjectConfig
---@field summary     LvimTestSummaryConfig
---@field output      LvimTestOutputConfig
---@field diagnostics LvimTestDiagnosticsConfig
---@field status      LvimTestStatusConfig
---@field watch       LvimTestWatchConfig
---@field icons       LvimTestIconsConfig

---@type LvimTestConfig
return {
    -- Built-in adapters to load (each self-registers from its own module). Remove a name to
    -- disable it; external adapters register themselves via require("lvim-test").register().
    -- Per-adapter options live under the matching key below — the max-configurability rule:
    -- an adapter never hardcodes what a user might want to change.
    adapters = {
        enabled = {
            "go",
            "dart",
            "rust",
            "python",
            "typescript",
            "cpp",
            "java",
            "csharp",
            "kotlin",
            "swift",
            "php",
            "ruby",
            "zig",
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
        kotlin = {
            args = {}, -- extra `gradle test` / `mvn test` args on every run
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
    },

    -- Discovery: the project WALK that lists candidate test files for the summary tree (parsing
    -- of a file's positions is separate + lazy — only on open / run / expand).
    discovery = {
        ignore_dirs = {
            ".git",
            "node_modules",
            "target",
            "build",
            ".build",
            "dist",
            ".venv",
            "__pycache__",
            "zig-out",
            ".zig-cache",
        },
        max_files = 5000, -- project-walk cap
    },

    -- The run pipeline. Every test process goes through lvim-tasks (output panel, matcher →
    -- quickfix, stop/restart) — nothing here spawns a job itself.
    run = {
        save = "current", -- write before running: "current" | "all" | false
        concurrent = false, -- allow parallel runs across different roots
        on_busy = "queue", -- a second request while running: "queue" | "replace" | "reject"
        missing_result = "skipped", -- status for ran-but-unreported positions
        open_panel = true, -- reveal the lvim-tasks panel (live output) when a run starts
        env = {}, -- extra env for every test process
    },

    -- Persistence through lvim-utils.store (json): last run, marks, and the last run's statuses
    -- (so signs come back on a fresh session).
    persist = {
        enabled = true,
        statuses = true,
    },

    -- Project-local overrides under the unified ".lvim" namespace (shared by the ecosystem).
    -- <root>/.lvim/test/config.lua returns a pure-data table merged over these defaults, e.g.
    --   { adapters = { go = { args = { "-race" } } }, run = { env = { CI = "1" } } }
    project = {
        dir = ".lvim",
        file = "test/config.lua",
    },

    -- The summary sidebar (a persistent docked tree, built on lvim-ui).
    summary = {
        side = "right", -- "right" | "left"
        width = 44,
        follow = true, -- tree cursor follows the editing position
        counts = true, -- aggregate pass/fail counts on dir/file rows
        expand_failed = true, -- auto-expand ancestors of failures after a run
        -- Every key is remappable; set one to false to disable it.
        keys = {
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

    -- Output windows: a per-test output float (lvim-ui) and the full-run terminal (tasks panel).
    output = {
        open_on_fail = "short", -- after a failed run: "short" | "full" | false
        max_height = 0.6, -- info-float caps (fraction of the editor, or absolute rows)
        max_width = 0.7,
    },

    -- Inline failure diagnostics (our own vim.diagnostic namespace; status signs are separate).
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

    -- Watch mode: re-run watched positions on save (debounced), scoped to the file or the project.
    watch = {
        debounce_ms = 300,
        scope = "project", -- "project" | "file"
    },

    -- Icons. Nerd Font, single-width (verified) — EXCEPT `running_frames`, the spinner, which is
    -- single-width braille (the ecosystem's established spinner idiom, shared with lvim-tasks).
    -- `pointer` is the canonical ➤ active-item marker.
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
}
