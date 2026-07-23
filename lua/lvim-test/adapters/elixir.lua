-- lvim-test.adapters.elixir: the Elixir (ExUnit) adapter.
-- Discovers ExUnit tests (`test "…"`) and their enclosing `describe "…"` groups via a treesitter
-- query, and runs them through `mix test`. ExUnit addresses a test by `<file>:<line>` (the line of its
-- `test` macro), so a single target becomes a `path:line` argument; a file target passes the file, a
-- dir runs the whole suite. `mix` is resolved through the lvim-lang Elixir toolchain first (honouring
-- the version manager), then PATH — lvim-test works fully without lvim-lang.
--
-- ExUnit has no built-in machine-readable per-test protocol, so results are parsed at the END from the
-- run output: the "N) test … (Module)" failure blocks give each failing test's `path:line` (mapped
-- back onto its discovered position by containment) + a `file.exs:LINE` diagnostic from the stacktrace,
-- and the "N tests, M failures" summary confirms the suite ran — so every OTHER covered test is marked
-- passed. A compile / setup failure (no summary, non-zero exit) marks the covered files failed. Precise
-- skipped/excluded mapping would need a custom ExUnit formatter (see the provider docs).
--
-- Per-test debugging is delegated to lvim-lang's Elixir DAP (the elixir-ls debugger).
--
---@module "lvim-test.adapters.elixir"

local config = require("lvim-test.config")

-- `describe "…"` calls → namespaces; `test "…"` calls → tests. The first argument (a description
-- string) is the display name; `#eq?` keeps only the ExUnit DSL macros so ordinary calls are ignored.
local QUERY = [[
(call
  target: (identifier) @_ns
  (arguments . (string) @namespace.name)
  (#eq? @_ns "describe")) @namespace.definition

(call
  target: (identifier) @_t
  (arguments . (string) @test.name)
  (#eq? @_t "test")) @test.definition
]]

local M = {}

--- The `mix` command prefix for a root: the lvim-lang Elixir toolchain when active, else PATH, else
--- the bare name. Returned as an argv list ending in `test`.
---@param root string
---@return string[]
local function mix_test_cmd(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("elixir", "mix", root)
        if resolved and resolved ~= "" then
            return { resolved, "test" }
        end
    end
    local p = vim.fn.exepath("mix")
    return { p ~= "" and p or "mix", "test" }
end

--- The project-relative path of `abs` (leading `./` stripped), for keying against ExUnit's reported
--- location (`test/foo_test.exs:5`).
---@param root string
---@param abs string
---@return string
local function rel_path(root, abs)
    local rel = vim.fs.relpath(root, abs) or vim.fn.fnamemodify(abs, ":t")
    return (rel:gsub("^%./", ""))
end

--- A position's 1-based definition line (the `test` / `describe` macro line ExUnit records), or nil.
---@param pos LvimTestPosition
---@return integer|nil
local function pos_line(pos)
    return pos.range and (pos.range[1] + 1) or nil
end

--- Collect the failure blocks from ExUnit output: each `N) test … (Module)` header, the bare
--- `path:line` location line under it (the test's registered line) and the stacktrace assertion line.
---@param lines string[]
---@return { rel: string, line: integer, short: string, errfile: string, errline: integer }[]
local function collect_failures(lines)
    local failures = {}
    local i = 1
    while i <= #lines do
        local num = lines[i]:match("^%s*(%d+)%)%s+%a")
        if num then
            local short = vim.trim((lines[i]:gsub("^%s*%d+%)%s+", "")))
            local rel, ln, errfile, errline
            local j = i + 1
            while j <= #lines and not lines[j]:match("^%s*%d+%)%s+%a") do
                if not rel then
                    -- The bare location line: "     test/foo_test.exs:5".
                    local f, l = lines[j]:match("^%s*([%w%._/%-]+_test%.exs):(%d+)%s*$")
                    if f then
                        rel, ln = f:gsub("^%./", ""), tonumber(l)
                    end
                end
                -- A stacktrace assertion line: "  test/foo_test.exs:6: (test …)".
                local sf, sl = lines[j]:match("([%w%._/%-]+%.exs):(%d+): %(test")
                if sf then
                    errfile, errline = sf:gsub("^%./", ""), tonumber(sl)
                end
                j = j + 1
            end
            if rel and ln then
                failures[#failures + 1] = {
                    rel = rel,
                    line = ln,
                    short = short,
                    errfile = errfile or rel,
                    errline = errline or ln,
                }
            end
            i = j
        else
            i = i + 1
        end
    end
    return failures
end

---@type LvimTestAdapter
local adapter = {
    name = "elixir",
    filetypes = { "elixir" },
    root_markers = { "mix.exs", ".git" },
    lang = "elixir",
    query = QUERY,
    toolchain_provider = "elixir",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("_test%.exs$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local args, seen = {}, {}

        local function add_arg(a)
            if not seen[a] then
                seen[a] = true
                args[#args + 1] = a
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" or t.kind == "namespace" then
                -- ExUnit addresses a test / group by `path:line` — the macro's start line.
                local line = pos_line(t)
                add_arg(line and (rel_path(root, t.path) .. ":" .. line) or rel_path(root, t.path))
            elseif t.kind == "file" then
                add_arg(rel_path(root, t.path))
            end -- dir: no arg → run the whole suite from the root
        end

        local a = config.adapters.elixir or {}
        local cmd = mix_test_cmd(root)
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, args)
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "generic",
            context = { root = root },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local root = ctx.context.root or ctx.root
        local lines = ctx.lines or {}
        local out = {}

        -- Did the suite actually run? ExUnit prints "N tests, M failures" (optionally with doctests /
        -- excluded / skipped) after "Finished in …". No summary + non-zero exit = a compile failure.
        local suite_ran = false
        for _, l in ipairs(lines) do
            if l:match("%d+ tests?, %d+ failures?") or l:match("%d+ doctests?, %d+ failures?") then
                suite_ran = true
                break
            end
        end

        if not suite_ran then
            if ctx.exit_code and ctx.exit_code ~= 0 then
                -- A compile / setup failure (no test ran) → mark the covered files failed so the error
                -- is visible instead of silently "skipped".
                local errors
                for _, l in ipairs(lines) do
                    local file, lnum = l:match("([%w%._/%-]+%.exs?):(%d+)")
                    if file then
                        errors =
                            { { message = vim.trim(l), path = vim.fs.joinpath(root, file), line = tonumber(lnum) } }
                        break
                    end
                end
                for _, pos in pairs(ctx.scope_map or {}) do
                    if pos.kind == "file" then
                        out[pos.id] = { status = "failed", short = "mix test failed", output = lines, errors = errors }
                    end
                end
            end
            return out
        end

        -- Index the covered test positions by relative path for containment-based failure resolution.
        ---@type table<string, LvimTestPosition[]>
        local by_file = {}
        for _, id in ipairs(ctx.covered or {}) do
            local pos = (ctx.scope_map or {})[id]
            if pos and pos.kind == "test" then
                local rel = rel_path(root, pos.path)
                by_file[rel] = by_file[rel] or {}
                by_file[rel][#by_file[rel] + 1] = pos
            end
        end

        -- Resolve a failure (rel path + macro line, with an assertion line fallback) onto a covered
        -- test position: an exact macro-line match, else the enclosing test by range containment.
        ---@param f { rel: string, line: integer, errline: integer }
        ---@return LvimTestPosition|nil
        local function resolve(f)
            local candidates = by_file[f.rel] or {}
            for _, pos in ipairs(candidates) do
                if pos_line(pos) == f.line then
                    return pos
                end
            end
            for _, pos in ipairs(candidates) do
                local s = pos.range and pos.range[1] or nil
                local e = pos.range and pos.range[3] or nil
                if s and e then
                    local probe = (f.errline or f.line) - 1
                    if probe >= s and probe <= e then
                        return pos
                    end
                end
            end
            return nil
        end

        local failed = {}
        for _, f in ipairs(collect_failures(lines)) do
            local pos = resolve(f)
            if pos then
                failed[pos.id] = true
                out[pos.id] = {
                    status = "failed",
                    short = f.short,
                    errors = { { message = f.short, path = vim.fs.joinpath(root, f.errfile), line = f.errline } },
                    output = lines,
                }
            end
        end

        -- The suite ran → every covered test that did not appear in a failure block passed.
        for _, id in ipairs(ctx.covered or {}) do
            local pos = (ctx.scope_map or {})[id]
            if pos and pos.kind == "test" and not failed[id] then
                out[id] = { status = "passed" }
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return table?
    debug = function(req)
        local ok = pcall(require, "lvim-lang.providers.elixir.dap")
        if not ok then
            return nil
        end
        local t = req.targets[1]
        if not t then
            return nil
        end
        local line = pos_line(t)
        local task_args = line and { t.path .. ":" .. line } or { t.path }
        return {
            type = "mix_task",
            request = "launch",
            name = "lvim-test: " .. t.name,
            task = "test",
            taskArgs = task_args,
            startApps = true,
            projectDir = "${workspaceFolder}",
            requireFiles = { "test/**/test_helper.exs", "test/**/*_test.exs" },
            cwd = req.root,
        }
    end,

    ---@param h table
    health = function(h)
        local root = vim.uv.cwd() or "."
        local cmd = mix_test_cmd(root)
        if vim.fn.executable(cmd[1]) == 1 then
            h.ok("mix: " .. cmd[1])
        else
            h.info("mix not found — install Elixir (mise / asdf) so `mix test` is available")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
