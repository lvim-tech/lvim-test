-- lvim-test.adapters.julia: the Julia adapter (Test.jl).
-- Discovers `@testset "name" begin … end` blocks via a treesitter query (the reportable unit — each
-- prints a `Test Summary: name | Pass … Fail …` line) and runs the suite through `Pkg.test()`. Test.jl
-- has no CLI per-testset filter, so a run executes the whole project suite; results map by testset name
-- from the summary lines (a testset with a non-zero Fail/Error column is marked failed, else passed).
--
-- When lvim-lang is installed and its Julia provider is active, `julia` is resolved through
-- `lvim-lang.core.toolchain` first, then PATH. lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.julia"

local config = require("lvim-test.config")

-- `@testset "name" begin … end` — a macrocall whose macro is `testset` and whose first argument is a
-- string literal. Nested testsets nest by range (the outer becomes a namespace of the inner).
local QUERY = [[
(macrocall_expression
  (macro_identifier) @_m
  (macro_argument_list (string_literal) @test.name)
  (#match? @_m "testset$")) @test.definition
]]

--- The `julia` binary for a root: the lvim-lang Julia toolchain when active, else PATH.
---@param root string
---@return string
local function julia_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("julia", "julia", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("julia")
    return p ~= "" and p or "julia"
end

--- Strip the surrounding quotes from a Julia string-literal node's text.
---@param s string
---@return string
local function unquote(s)
    return (s:gsub('^"', ""):gsub('"$', ""))
end

---@type LvimTestAdapter
local adapter = {
    name = "julia",
    filetypes = { "julia" },
    lang = "julia",
    root_markers = { "Project.toml", "JuliaProject.toml", ".git" },
    toolchain_provider = "julia",
    query = QUERY,

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("[/\\]test[/\\].*%.jl$") ~= nil or path:match("runtests%.jl$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local a = config.adapters.julia or {}
        -- Map every covered testset name → id so summary lines resolve (Test.jl runs the whole suite).
        local by_name = {}
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[pos.name] = pos.id
            end
        end
        local cmd = { julia_bin(root), "--project=" .. (a.project or "."), "-e", "using Pkg; Pkg.test()" }
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})
        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            context = { by_name = by_name },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        -- `Test Summary: <name> | Pass  Fail  Error  Broken  Total` — a Fail/Error column marks failure.
        for _, line in ipairs(ctx.lines or {}) do
            local name = line:match("^%s*Test Summary:%s+(.-)%s+|")
            if name then
                local id = c.by_name[unquote(vim.trim(name))] or c.by_name[vim.trim(name)]
                if id then
                    local failed = line:match("Fail") ~= nil or line:match("Error") ~= nil
                    out[id] = { status = failed and "failed" or "passed", short = failed and vim.trim(line) or nil }
                end
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("julia") == "" then
            h.warn("julia not found on PATH")
        else
            h.ok("julia: " .. vim.fn.exepath("julia"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
