-- lvim-test.adapters.go: the Go adapter.
-- Discovers top-level `Test*`/`Example*` functions via a treesitter query, runs them through
-- `go test -json` (one package per test's directory, filtered with `-run ^(…)$`), and maps the
-- streamed JSON events back onto positions live — the streaming showcase: each `pass`/`fail`/`skip`
-- event flips a position's status while the run continues, `output` events accumulate a test's
-- own lines, and a `file.go:NN:` prefix inside that output becomes an inline diagnostic.
--
-- Subtests (`t.Run`) are dynamic (names computed at runtime) so they are not discovered
-- statically; a `TestFoo/sub` result folds onto its parent `TestFoo` position (documented; per-
-- subtest positions are a later idea).
--
---@module "lvim-test.adapters.go"

local config = require("lvim-test.config")

-- Top-level test/example function declarations. The definition node is the whole declaration
-- (its range drives cursor-nearest + signs); the name node's text is the runner-side test name.
local QUERY = [[
(function_declaration
  name: (identifier) @test.name
  (#match? @test.name "^(Test|Example)"))
@test.definition
]]

local M = {}

--- The `go` binary for a root (PATH for now; the lvim-lang toolchain seam is added with the
--- later adapters). Falls back to the bare name so the task still reports a clean "not found".
---@param _root string
---@return string
local function go_bin(_root)
    local p = vim.fn.exepath("go")
    return p ~= "" and p or "go"
end

--- A file's package directory RELATIVE to the module root ("" = the root package), as a `./x/`
--- package pattern go understands.
---@param path string
---@param root string
---@return string  e.g. "pkg/sub" ("" for the root)
local function rel_pkg(path, root)
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir == root then
        return ""
    end
    local rel = dir:sub(#root + 2) -- strip "root/"
    return rel
end

---@type LvimTestAdapter
local adapter = {
    name = "go",
    filetypes = { "go" },
    root_markers = { "go.mod", ".git" },
    lang = "go",
    query = QUERY,
    toolchain_provider = "go",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("_test%.go$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        -- Collect test names + packages from the targets (a test → itself; a file → its tests).
        local names, name_seen = {}, {}
        local pkgs, pkg_seen = {}, {}
        ---@type table<string, string>  runner test name → position id (for result mapping)
        local by_name = {}

        local function add_test(pos)
            local run_name = (pos.data and pos.data.run) or pos.name
            if not name_seen[run_name] then
                name_seen[run_name] = true
                names[#names + 1] = run_name
            end
            by_name[run_name] = pos.id
            local pkg = rel_pkg(pos.path, root)
            if not pkg_seen[pkg] then
                pkg_seen[pkg] = true
                pkgs[#pkgs + 1] = pkg
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" or t.kind == "namespace" then
                add_test(t)
            elseif t.kind == "file" or t.kind == "dir" then
                -- expand to the tests in scope that belong to this file (or, for a dir, every test)
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and (t.kind == "dir" or pos.path == t.path) then
                        add_test(pos)
                    end
                end
            end
        end
        -- Map EVERY covered test name in scope (so streamed events for siblings still resolve).
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[pos.name] = pos.id
            end
        end

        local go = go_bin(root)
        local cmd = { go, "test", "-json" }
        local a = config.adapters.go
        if a.tags and a.tags ~= "" then
            vim.list_extend(cmd, { "-tags", a.tags })
        end
        if #names > 0 then
            table.insert(cmd, "-run")
            table.insert(cmd, "^(" .. table.concat(names, "|") .. ")$")
        end
        if #pkgs == 0 then
            table.insert(cmd, "./...")
        else
            for _, pkg in ipairs(pkgs) do
                table.insert(cmd, pkg == "" and "." or ("./" .. pkg .. "/"))
            end
        end
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "go",
            context = { by_name = by_name, output = {}, build_out = {}, build_fail = false },
        }
    end,

    ---@param line string
    ---@param ctx table
    ---@return table<string, LvimTestResult>?
    stream = function(line, ctx)
        if line == "" or line:sub(1, 1) ~= "{" then
            ctx.context.build_out[#ctx.context.build_out + 1] = line
            return nil
        end
        local ok, ev = pcall(vim.json.decode, line)
        if not ok or type(ev) ~= "table" or not ev.Action then
            return nil
        end
        local c = ctx.context
        -- A test-less fail = a package build/compile failure; keep its output for parse().
        if ev.Test == nil or ev.Test == "" then
            if ev.Action == "output" and ev.Output then
                c.build_out[#c.build_out + 1] = (ev.Output:gsub("\n$", ""))
            elseif ev.Action == "fail" then
                c.build_fail = true
            end
            return nil
        end
        local top = ev.Test:match("^[^/]+") or ev.Test
        local id = c.by_name[top]
        if not id then
            return nil
        end
        if ev.Action == "output" then
            local acc = c.output[id] or {}
            acc[#acc + 1] = (ev.Output or ""):gsub("\n$", "")
            c.output[id] = acc
            return nil
        elseif ev.Action == "pass" then
            return { [id] = { status = "passed" } }
        elseif ev.Action == "skip" then
            return { [id] = { status = "skipped" } }
        elseif ev.Action == "fail" then
            local out = c.output[id] or {}
            local short, errors
            for _, l in ipairs(out) do
                local file, lnum = l:match("(%S+%.go):(%d+):")
                if file and not short then
                    short = vim.trim(l)
                    errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                end
            end
            return { [id] = { status = "failed", output = out, short = short, errors = errors } }
        end
        return nil
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        -- Streaming already produced per-test statuses. Here we only handle a package build/compile
        -- failure (no per-test events): mark every covered file position failed with the compiler
        -- output, so the error is visible instead of silently "skipped".
        local c = ctx.context
        if not (c.build_fail or (ctx.exit_code and ctx.exit_code ~= 0)) then
            return {}
        end
        local produced = false
        for _, id in ipairs(ctx.covered) do
            local r = require("lvim-test.results").get(ctx.root, id)
            if r and (r.status == "passed" or r.status == "failed") then
                produced = true
                break
            end
        end
        if produced then
            return {}
        end
        -- No test produced a status and the run failed → a build error. Attach it to file positions.
        local msg = table.concat(c.build_out, "\n")
        local errors
        for _, l in ipairs(c.build_out) do
            local file, lnum = l:match("(%S+%.go):(%d+):")
            if file then
                errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                break
            end
        end
        local out = {}
        local files = {}
        for _, pos in pairs(ctx.scope_map) do
            if pos.kind == "file" then
                files[pos.id] = true
            end
        end
        for _, id in ipairs(ctx.covered) do
            local pos = ctx.scope_map[id]
            if pos and pos.kind == "file" then
                out[id] = { status = "failed", short = "build failed", output = c.build_out, errors = errors }
            end
        end
        if not next(out) and next(files) then
            for id in pairs(files) do
                out[id] = { status = "failed", short = "build failed", output = c.build_out, errors = errors }
            end
        end
        if msg == "" then
            -- nothing captured; still surface a failure on the covered files
            for id in pairs(files) do
                out[id] = out[id] or { status = "failed", short = "build failed" }
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return table?
    debug = function(req)
        local t = req.targets[1]
        if not t then
            return nil
        end
        local dir = vim.fn.fnamemodify(t.path, ":h")
        local name = (t.data and t.data.run) or t.name
        return {
            type = "go",
            name = "lvim-test: " .. name,
            request = "launch",
            mode = "test",
            program = dir,
            args = { "-test.run", "^" .. name .. "$" },
        }
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("go") == "" then
            h.warn("go not found on PATH")
        else
            h.ok("go: " .. vim.fn.exepath("go"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
