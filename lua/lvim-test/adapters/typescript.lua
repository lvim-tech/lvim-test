-- lvim-test.adapters.typescript: the TypeScript / JavaScript adapter (vitest / jest).
-- Discovers `it(...)` / `test(...)` calls (and `describe(...)` namespaces) via a treesitter query
-- across all four JS/TS filetypes, and runs them through the project's runner — vitest or jest,
-- detected from the config files / devDependencies. Both runners emit the SAME jest-shaped JSON
-- report (`--reporter=json` / `--json` to an `--outputFile`), parsed at the end and mapped onto
-- positions by each test's FULL title (its `describe` lineage + its own title). A failure's message
-- becomes the short summary + a `file:line` diagnostic pulled from its stack.
--
-- The adapter pins no treesitter language, so the engine resolves it per file (typescript / tsx /
-- javascript). The runner binary prefers the project's `node_modules/.bin`, then `npx`.
--
---@module "lvim-test.adapters.typescript"

local config = require("lvim-test.config")

-- `describe(...)` → namespace, `it(...)` / `test(...)` (incl. `.only` / `.skip`) → test. The title is
-- the first string argument (its surrounding quotes are stripped by the discovery engine).
local QUERY = [[
(call_expression
  function: (identifier) @_ns (#eq? @_ns "describe")
  arguments: (arguments (string) @namespace.name)) @namespace.definition
(call_expression
  function: [(identifier) @_t (member_expression object: (identifier) @_t)]
  (#any-of? @_t "it" "test")
  arguments: (arguments (string) @test.name)) @test.definition
]]

local M = {}

--- Whether a root is a jest project (config file or a jest devDependency / test script), else vitest.
---@param root string
---@return "vitest"|"jest"
local function detect_runner(root)
    local pinned = (config.adapters.typescript or {}).runner
    if pinned == "vitest" or pinned == "jest" then
        return pinned
    end
    for _, f in ipairs({ "vitest.config.ts", "vitest.config.js", "vitest.config.mjs", "vitest.workspace.ts" }) do
        if vim.fn.filereadable(vim.fs.joinpath(root, f)) == 1 then
            return "vitest"
        end
    end
    for _, f in ipairs({ "jest.config.ts", "jest.config.js", "jest.config.mjs", "jest.config.json" }) do
        if vim.fn.filereadable(vim.fs.joinpath(root, f)) == 1 then
            return "jest"
        end
    end
    local pkgpath = vim.fs.joinpath(root, "package.json")
    if vim.fn.filereadable(pkgpath) == 1 then
        local ok, pkg = pcall(vim.json.decode, table.concat(vim.fn.readfile(pkgpath), "\n"))
        if ok and type(pkg) == "table" then
            local dev = pkg.devDependencies or {}
            local deps = pkg.dependencies or {}
            if dev.jest or deps.jest then
                return "jest"
            end
            if dev.vitest or deps.vitest then
                return "vitest"
            end
        end
    end
    return "vitest"
end

--- The command that runs `runner` at a root: the project-local `node_modules/.bin` binary, else
--- `npx <runner>` (which uses the local install when present).
---@param root string
---@param runner string
---@return string[]
local function runner_cmd(root, runner)
    local pkg_root = vim.fs.root(root, { "package.json" }) or root
    local bin = vim.fs.joinpath(pkg_root, "node_modules", ".bin", runner)
    if vim.fn.executable(bin) == 1 then
        return { bin }
    end
    return { "npx", runner }
end

--- A position's FULL title: its `describe` lineage + its own title, space joined (the name vitest /
--- jest report as `fullName`).
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function full_name(map, pos)
    local parts = { pos.name }
    local p = pos.parent and map[pos.parent]
    while p and p.kind == "namespace" do
        table.insert(parts, 1, p.name)
        p = p.parent and map[p.parent]
    end
    return table.concat(parts, " ")
end

---@type LvimTestAdapter
local adapter = {
    name = "typescript",
    filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
    root_markers = { "package.json", "tsconfig.json", "jsconfig.json", ".git" },
    -- no `lang`: the engine resolves typescript / tsx / javascript per file.
    query = QUERY,
    toolchain_provider = "typescript",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("%.[cm]?[jt]sx?$")
            and (path:match("%.test%.") or path:match("%.spec%.") or path:match("__tests__")) ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local runner = detect_runner(root)
        local cmd = runner_cmd(root, runner)
        if runner == "vitest" then
            cmd[#cmd + 1] = "run"
        end

        -- Files to run + an optional single title filter. One specific test/namespace → `-t <title>`;
        -- otherwise run the target files (or the whole project for a dir).
        local files, file_seen = {}, {}
        local single_title
        local specific = {}
        local function add_file(p)
            if not file_seen[p] then
                file_seen[p] = true
                files[#files + 1] = p
            end
        end
        for _, t in ipairs(req.targets) do
            if t.kind == "test" or t.kind == "namespace" then
                specific[#specific + 1] = t
                add_file(t.path)
            elseif t.kind == "file" then
                add_file(t.path)
            end -- dir: run everything
        end
        if #specific == 1 then
            single_title = full_name(req.scope_map, specific[1])
        end

        vim.list_extend(cmd, files)
        if single_title then
            vim.list_extend(cmd, { "-t", single_title })
        end

        -- Both runners emit the jest JSON shape to an --outputFile; parse reads it at the end.
        local report = vim.fn.tempname() .. ".json"
        if runner == "vitest" then
            vim.list_extend(cmd, { "--reporter=json", "--outputFile=" .. report })
        else
            vim.list_extend(cmd, { "--json", "--outputFile=" .. report })
        end
        local a = config.adapters.typescript or {}
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        ---@type table<string, string>  full title → id
        local by_fullname = {}
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_fullname[full_name(req.scope_map, pos)] = pos.id
            end
        end

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "typescript",
            context = { report = report, by_fullname = by_fullname, root = root },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        if vim.fn.filereadable(c.report) ~= 1 then
            return out
        end
        local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(c.report), "\n"))
        pcall(vim.fn.delete, c.report)
        if not ok or type(data) ~= "table" or type(data.testResults) ~= "table" then
            return out
        end
        for _, file in ipairs(data.testResults) do
            for _, ar in ipairs(file.assertionResults or {}) do
                local full = ar.fullName
                if not full or full == "" then
                    local parts = vim.deepcopy(ar.ancestorTitles or {})
                    parts[#parts + 1] = ar.title
                    full = table.concat(parts, " ")
                end
                local id = c.by_fullname[full]
                if id then
                    if ar.status == "passed" then
                        out[id] = { status = "passed" }
                    elseif ar.status == "pending" or ar.status == "skipped" or ar.status == "todo" then
                        out[id] = { status = "skipped" }
                    else -- failed
                        local msg = (ar.failureMessages or {})[1] or ""
                        local first = vim.split(msg, "\n", { plain = true })[1] or "test failed"
                        local path, lnum = msg:match("%((%S-):(%d+):%d+%)")
                        out[id] = {
                            status = "failed",
                            output = msg ~= "" and vim.split(msg, "\n", { plain = true }) or nil,
                            short = vim.trim(first),
                            errors = path and { { message = vim.trim(first), path = path, line = tonumber(lnum) } }
                                or nil,
                        }
                    end
                end
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
        local runner = detect_runner(req.root)
        local pkg_root = vim.fs.root(req.root, { "package.json" }) or req.root
        local bin = vim.fs.joinpath(pkg_root, "node_modules", ".bin", runner)
        if vim.fn.executable(bin) ~= 1 then
            return nil
        end
        local args = { runner == "vitest" and "run" or nil, t.path, "-t", full_name(req.scope_map, t) }
        return {
            type = "pwa-node",
            name = "lvim-test: " .. t.name,
            request = "launch",
            program = bin,
            args = vim.tbl_filter(function(x)
                return x ~= nil
            end, args),
            cwd = req.root,
            console = "integratedTerminal",
            skipFiles = { "<node_internals>/**" },
        }
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("node") == "" then
            h.warn("node not found on PATH")
        else
            h.ok("node: " .. vim.fn.exepath("node"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
