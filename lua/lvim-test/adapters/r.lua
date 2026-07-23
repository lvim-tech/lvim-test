-- lvim-test.adapters.r: the R adapter (testthat).
-- Discovers `test_that("desc", { … })` blocks via a treesitter query (for the tree) and runs a test
-- file through `testthat::test_file()` (or the whole suite via `devtools::test()` for a dir/namespace).
-- testthat has no CLI per-`test_that` filter, so a run executes at FILE granularity; a file with any
-- reported failure (its `[ FAIL n … ]` line, n > 0) is marked failed, else passed.
--
-- When lvim-lang is installed and its R provider is active, `R` / `Rscript` are resolved through
-- `lvim-lang.core.toolchain` first, then PATH. lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.r"

local config = require("lvim-test.config")

-- `test_that("desc", { … })` — a call to `test_that` whose first argument is a string.
local QUERY = [[
(call
  function: (identifier) @_fn
  arguments: (arguments (argument (string) @test.name))
  (#eq? @_fn "test_that")) @test.definition
]]

--- The `Rscript` binary for a root: derived from the lvim-lang R toolchain when active, else PATH.
---@param root string
---@return string
local function rscript_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local R = tc.resolve("r", "R", root)
        if R and R ~= "" then
            local rs = R:gsub("R$", "Rscript")
            if rs ~= R and vim.fn.executable(rs) == 1 then
                return rs
            end
        end
    end
    local p = vim.fn.exepath("Rscript")
    return p ~= "" and p or "Rscript"
end

---@type LvimTestAdapter
local adapter = {
    name = "r",
    filetypes = { "r", "rmd" },
    lang = "r",
    root_markers = { "DESCRIPTION", ".git" },
    toolchain_provider = "r",
    query = QUERY,

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("[/\\]tests[/\\]testthat[/\\]test.*%.[rR]$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local a = config.adapters.r or {}
        -- The set of test files covered by the request (testthat runs per file).
        local files, seen, file_ids = {}, {}, {}
        for _, t in ipairs(req.targets) do
            if t.path and not seen[t.path] then
                seen[t.path] = true
                files[#files + 1] = t.path
            end
        end
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "file" then
                file_ids[pos.path] = pos.id
            end
        end
        local rscript = rscript_bin(root)
        local cmd
        if #files == 1 then
            cmd = { rscript, "-e", ("testthat::test_file('%s')"):format(files[1]:gsub("'", "\\'")) }
        else
            cmd = { rscript, "-e", "devtools::test()" }
        end
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})
        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            context = { file_ids = file_ids, single = files[1] },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        -- testthat's summary line: `[ FAIL n | WARN n | SKIP n | PASS n ]` — FAIL > 0 → failure.
        local fails = 0
        for _, line in ipairs(ctx.lines or {}) do
            local n = line:match("FAIL%s+(%d+)")
            if n then
                fails = math.max(fails, tonumber(n) or 0)
            end
        end
        local failed = fails > 0 or (ctx.exit_code and ctx.exit_code ~= 0)
        -- File granularity: mark the covered file position(s).
        for _, pos in pairs(ctx.scope_map or {}) do
            if pos.kind == "file" and (not c.single or pos.path == c.single) then
                out[pos.id] = { status = failed and "failed" or "passed", output = failed and ctx.lines or nil }
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("Rscript") == "" then
            h.warn("Rscript not found on PATH")
        else
            h.ok("Rscript: " .. vim.fn.exepath("Rscript"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
