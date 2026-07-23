-- lvim-test.adapters.erlang: the Erlang (EUnit) adapter.
-- Discovers EUnit test functions — those named `*_test` (a simple test) or `*_test_` (a test
-- GENERATOR) — via a treesitter query over `fun_decl` clauses, and runs them through `rebar3 eunit`
-- (a test → `--test=<module>:<function>`, a file → `--module=<module>`, a dir → the whole project).
-- EUnit has no machine-readable report, so results are parsed from its VERBOSE output (`-v`): each
-- covered test's `<module>:<function>` is known up-front, so the parse anchors on THOSE names rather
-- than guessing EUnit's line format — a line naming a covered test and ending in `ok` passes it, one
-- carrying `*failed*` / `*error*` / `*cancelled*` fails it. A compile / load failure (no test mapped,
-- non-zero exit) marks the covered file positions failed so the error is visible.
--
-- When lvim-lang is installed and its Erlang provider is active, the `rebar3` binary is resolved
-- through `lvim-lang.core.toolchain` first (honouring the version manager / an explicit path), then
-- PATH. lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.erlang"

local config = require("lvim-test.config")

-- `fun_decl` clauses whose function name atom ends in `_test` / `_test_` are EUnit tests. The
-- definition node is the whole declaration (its range drives cursor-nearest + signs); the name atom's
-- text is the runner-side function name. (tree-sitter-erlang: `function_clause` carries a `name:`
-- field that is an `atom`.)
local QUERY = [[
(fun_decl
  (function_clause
    name: (atom) @test.name)
  (#match? @test.name "_test_?$")) @test.definition
]]

local M = {}

--- The `rebar3` binary for a root: the lvim-lang Erlang toolchain when active, else PATH, else the name.
---@param root string
---@return string
local function rebar3_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("erlang", "rebar3", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("rebar3")
    return p ~= "" and p or "rebar3"
end

--- The Erlang module name for a source file: its basename without the `.erl` extension.
---@param path string
---@return string
local function module_of(path)
    return (vim.fn.fnamemodify(path, ":t"):gsub("%.erl$", ""))
end

---@type LvimTestAdapter
local adapter = {
    name = "erlang",
    filetypes = { "erlang" },
    root_markers = { "rebar.config", "erlang.mk", ".git" },
    lang = "erlang",
    query = QUERY,
    toolchain_provider = "erlang",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        -- EUnit tests live in any module (inline `*_test` functions, or a `<module>_tests.erl`
        -- companion): every `.erl` is a candidate; the treesitter query surfaces only files that
        -- actually contain test functions.
        return path:match("%.erl$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local filters, seen = {}, {}
        ---@type table<string, string>  "<module>:<function>" AND leaf function name → position id
        local by_name = {}

        local function add_filter(f)
            if not seen[f] then
                seen[f] = true
                filters[#filters + 1] = f
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add_filter("--test=" .. module_of(t.path) .. ":" .. t.name)
            elseif t.kind == "file" then
                add_filter("--module=" .. module_of(t.path))
            end -- namespace: none in this grammar; dir: no filter → the whole project
        end
        -- Map EVERY covered test by (module:function) and by leaf name so parsed lines resolve.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[module_of(pos.path) .. ":" .. pos.name] = pos.id
                by_name[pos.name] = pos.id
            end
        end

        local a = config.adapters.erlang or {}
        -- Verbose so EUnit prints a line per test (its default progress listener prints only dots).
        local cmd = { rebar3_bin(root), "eunit", "-v" }
        vim.list_extend(cmd, filters)
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "generic",
            context = { by_name = by_name },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        local lines = ctx.lines or {}

        -- Name-anchored scan: for each covered test name we injected, find the output line(s) that
        -- mention it and read the trailing outcome. Anchoring on OUR names (not EUnit's line shape)
        -- keeps this robust across EUnit's formatting variations.
        for name, id in pairs(c.by_name) do
            -- Only the leaf-function keys carry a `_test` suffix; skip the "module:function" duplicate
            -- to avoid scanning twice for the same position.
            if not name:find(":", 1, true) then
                local pat = vim.pesc(name)
                for _, line in ipairs(lines) do
                    if line:find(pat, 1, true) then
                        if line:match("%*failed%*") or line:match("%*error%*") or line:match("%*cancelled%*") then
                            out[id] = { status = "failed", short = vim.trim(line) }
                        elseif line:match("%.%.%.%s*%[?[%d%.%s]*s?%]?%s*ok%s*$") or line:match("%.%.%.ok%s*$") then
                            -- Do not downgrade a failure already recorded for this position.
                            if not (out[id] and out[id].status == "failed") then
                                out[id] = { status = "passed" }
                            end
                        elseif line:match("%.%.%.%s*skipped") then
                            if not (out[id] and out[id].status == "failed") then
                                out[id] = { status = "skipped" }
                            end
                        end
                    end
                end
            end
        end

        -- Attach a `file.erl:LINE` diagnostic to each failed test from a matching output line.
        for id, res in pairs(out) do
            if res.status == "failed" then
                local pos = (ctx.scope_map or {})[id]
                local tail = pos and vim.fn.fnamemodify(pos.path, ":t")
                if tail then
                    for _, line in ipairs(lines) do
                        local lnum = line:match(vim.pesc(tail) .. ":(%d+)")
                        if lnum then
                            res.errors =
                                { { message = res.short or "test failed", path = pos.path, line = tonumber(lnum) } }
                            break
                        end
                    end
                end
            end
        end

        -- No test mapped and the run failed → a compile / load error. Mark the covered file positions
        -- failed so the error is visible instead of a silent "skipped".
        if next(out) == nil and ctx.exit_code and ctx.exit_code ~= 0 then
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] = { status = "failed", short = "rebar3 eunit failed", output = lines }
                end
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("rebar3") == "" then
            h.warn("rebar3 not found on PATH")
        else
            h.ok("rebar3: " .. vim.fn.exepath("rebar3"))
        end
        if vim.fn.exepath("erl") == "" then
            h.warn("erl (Erlang/OTP) not found on PATH")
        else
            h.ok("erl: " .. vim.fn.exepath("erl"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
