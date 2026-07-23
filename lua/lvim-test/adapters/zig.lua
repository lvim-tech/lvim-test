-- lvim-test.adapters.zig: the Zig adapter.
-- Discovers `test "name" { … }` blocks via a treesitter query (Zig tests are named string blocks,
-- not functions, and have no enclosing namespace) and runs them through `zig test`. Zig's test
-- runner streams a line per test — `N/M <module>.test.<name>...OK|SKIP|FAIL (reason)` — so statuses
-- flip live from that human output; a `FAIL`'s following traceback (`file.zig:line:col: … in
-- test.<name>`) becomes the position's short message + an inline diagnostic. A compile failure marks
-- the covered file positions failed.
--
-- Zig's test unit is the FILE (`zig test <file>`), filtered by `--test-filter <name>` (a SUBSTRING
-- match, repeatable / OR). So a single file / test / nearest run targets that one file with the
-- requested names; a broad run (a directory, or a project with a build.zig) runs `zig build test`,
-- whose output is the same streamed format, so results still map by name.
--
-- When lvim-lang is installed and its Zig provider is active, the `zig` binary is resolved through
-- `lvim-lang.core.toolchain` first (honouring an explicit path / mise / asdf), then PATH. lvim-test
-- works fully without lvim-lang.
--
---@module "lvim-test.adapters.zig"

local config = require("lvim-test.config")

-- `test "name" { … }` blocks → tests. The `.definition` is the whole test_declaration (its range
-- drives cursor-nearest + signs); the `(string)` child's text (quotes stripped by discovery) is the
-- test name. Zig has no test namespaces, so only `@test.*` captures.
local QUERY = [[
(test_declaration
  (string) @test.name) @test.definition
]]

local M = {}

--- The `zig` binary for a root: the lvim-lang Zig toolchain when active, else PATH, else the name.
---@param root string
---@return string
local function zig_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("zig", "zig", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("zig")
    return p ~= "" and p or "zig"
end

--- The test's own name from a streamed `<module>.test.<name>` runner id (the text after the last
--- `.test.`), or the id unchanged when it carries no such prefix.
---@param runner_name string
---@return string
local function leaf_of(runner_name)
    return runner_name:match("%.test%.(.+)$") or runner_name
end

---@type LvimTestAdapter
local adapter = {
    name = "zig",
    filetypes = { "zig" },
    root_markers = { "build.zig", "build.zig.zon", ".git" },
    lang = "zig",
    query = QUERY,
    toolchain_provider = "zig",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        -- Zig tests live inline in any `.zig` file; the treesitter query surfaces only files that
        -- actually contain a `test` block.
        return path:match("%.zig$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        ---@type table<string, string>  test display name → position id (for result mapping)
        local by_name = {}
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[pos.name] = pos.id
            end
        end

        -- Collect the files in scope + the individual test names to filter on. A `test`-kind target
        -- filters to its own name; a `file`/`namespace` target runs that whole file (no filter); a
        -- `dir` target is broad (whole suite).
        local files, file_seen = {}, {}
        local filters = {}
        local has_dir = false
        local function add_file(path)
            if path and not file_seen[path] then
                file_seen[path] = true
                files[#files + 1] = path
            end
        end
        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add_file(t.path)
                filters[#filters + 1] = t.name
            elseif t.kind == "file" or t.kind == "namespace" then
                add_file(t.path)
            elseif t.kind == "dir" then
                has_dir = true
            end
        end

        local zig = zig_bin(root)
        local a = config.adapters.zig or {}
        local cmd
        if not has_dir and #files == 1 then
            -- Narrow: one file — run it, filtered to the requested tests (none → the whole file).
            cmd = { zig, "test", files[1] }
            for _, name in ipairs(filters) do
                cmd[#cmd + 1] = "--test-filter"
                cmd[#cmd + 1] = name
            end
        elseif vim.fn.filereadable(root .. "/build.zig") == 1 then
            -- Broad, and a build.zig owns the suite — run the project's test step.
            cmd = { zig, "build", "test" }
        elseif #files >= 1 then
            -- Broad, no build.zig — best effort: the first file in scope (single-file layouts).
            cmd = { zig, "test", files[1] }
            for _, name in ipairs(filters) do
                cmd[#cmd + 1] = "--test-filter"
                cmd[#cmd + 1] = name
            end
        else
            return nil
        end
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "gcc",
            context = { by_name = by_name, cur_fail = nil, fail_out = {} },
        }
    end,

    ---@param line string
    ---@param ctx table
    ---@return table<string, LvimTestResult>?
    stream = function(line, ctx)
        local c = ctx.context
        -- `N/M <module>.test.<name>...OK|SKIP|FAIL (reason)`.
        local name, status, extra = line:match("^%d+/%d+%s+(.-)%.%.%.(%a+)%s*(.*)$")
        if name and status then
            local id = c.by_name[name] or c.by_name[leaf_of(name)]
            if status == "OK" then
                c.cur_fail = nil
                if id then
                    return { [id] = { status = "passed" } }
                end
            elseif status == "SKIP" then
                c.cur_fail = nil
                if id then
                    return { [id] = { status = "skipped" } }
                end
            elseif status == "FAIL" then
                -- Start accumulating the traceback lines that follow, for parse() to attach.
                c.cur_fail = id
                if id then
                    local reason = extra:match("%((.-)%)")
                    c.fail_out[id] = { reason = reason, lines = {} }
                    return { [id] = { status = "failed", short = reason } }
                end
            end
            return nil
        end
        -- A non-status line while a failure is open: it belongs to that test's traceback (until the
        -- summary line `N passed; …` or the next `N/M` status line, both handled above).
        if c.cur_fail and c.fail_out[c.cur_fail] and not line:match("^%d+ passed;") then
            local fo = c.fail_out[c.cur_fail]
            fo.lines[#fo.lines + 1] = line
        end
        return nil
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        -- Attach each failure's traceback: the reason as the short message, and the first Zig source
        -- location as an inline diagnostic.
        for id, fo in pairs(c.fail_out or {}) do
            local errors
            for _, l in ipairs(fo.lines or {}) do
                local file, lnum = l:match("(%S+%.zig):(%d+):%d+")
                if file then
                    errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                    break
                end
            end
            out[id] = {
                status = "failed",
                output = fo.lines,
                short = fo.reason or (fo.lines[1] and vim.trim(fo.lines[1])) or "test failed",
                errors = errors,
            }
        end

        -- Compile failure: the run failed and no covered test produced a status → mark the files.
        local produced = false
        for _, id in ipairs(ctx.covered or {}) do
            local r = require("lvim-test.results").get(ctx.root, id)
            if r and (r.status == "passed" or r.status == "failed") then
                produced = true
                break
            end
        end
        if not produced and ctx.exit_code and ctx.exit_code ~= 0 then
            local errors
            for _, l in ipairs(ctx.lines or {}) do
                local file, lnum = l:match("(%S+%.zig):(%d+):%d+")
                if file then
                    errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                    break
                end
            end
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] = { status = "failed", short = "build failed", output = ctx.lines, errors = errors }
                end
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("zig") == "" then
            h.warn("zig not found on PATH")
        else
            h.ok("zig: " .. vim.fn.exepath("zig"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
