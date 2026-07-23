-- lvim-test.adapters.clojure: the Clojure (clojure.test) adapter.
-- Discovers `deftest` / `defspec` forms via a treesitter query — a `(deftest <name> …)` list whose
-- head symbol is a test-defining form, its second symbol the test name — and runs them through the
-- project's build tool: the Clojure CLI (`clojure -X:test`, the Cognitect test-runner convention),
-- Leiningen (`lein test`) or Boot (`boot test`), auto-detected at the root. Both the CLI exec runner
-- and Leiningen filter to specific tests (`:vars '[ns/test]'` / `:only ns/test`) or whole namespaces
-- (`:nses '[ns]'` / `lein test ns`); a `-M` CLI alias and Boot cannot filter, so they run the whole
-- suite and results map back by name.
--
-- clojure.test emits no per-test PASS line — only `FAIL in (name) (file:line)` / `ERROR in (name)`
-- blocks — so results are parsed at the END: a covered test named in a FAIL/ERROR block is failed
-- (with the file:line diagnostic), and every other covered test that RAN (the runner printed
-- `Ran N tests`) passed. A run that failed before any test ran (a compile/require error) marks the
-- covered files failed. The namespace of each test is read from its file's `(ns …)` form.
--
-- When lvim-lang is installed and its Clojure provider is active, the `clojure` / `lein` / `boot`
-- binary is resolved through `lvim-lang.core.toolchain` first (honouring a version manager / an
-- explicit SDK), then PATH. lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.clojure"

local config = require("lvim-test.config")

-- `(deftest name …)` / `(defspec name …)` → tests. The leading `.` anchors the head symbol as the
-- first named child and the `.` between the two symbols keeps the name IMMEDIATELY after the head, so
-- only the test's own name is captured (never a symbol from the body). `#any-of?` keeps test forms.
local QUERY = [[
(list_lit
  .
  (sym_lit (sym_name) @_kw)
  .
  (sym_lit (sym_name) @test.name)
  (#any-of? @_kw "deftest" "deftest-" "defspec")) @test.definition
]]

local M = {}

--- Resolve `tool` ("clojure" | "lein" | "boot"): the lvim-lang Clojure toolchain when active for
--- `root`, else PATH, else the bare name.
---@param tool string
---@param root string
---@return string
local function bin(tool, root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("clojure", tool, root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath(tool)
    return p ~= "" and p or tool
end

--- The build tool for a root: "clj" (a `deps.edn`) → "lein" (a `project.clj`) → "boot" (a
--- `build.boot`) → nil when none is present.
---@param root string
---@return "clj"|"lein"|"boot"|nil
local function detect_tool(root)
    if vim.fn.filereadable(vim.fs.joinpath(root, "deps.edn")) == 1 then
        return "clj"
    end
    if vim.fn.filereadable(vim.fs.joinpath(root, "project.clj")) == 1 then
        return "lein"
    end
    if vim.fn.filereadable(vim.fs.joinpath(root, "build.boot")) == 1 then
        return "boot"
    end
    return nil
end

--- The `(ns <namespace> …)` name declared in a source file, or nil — read straight from the text
--- (the adapter needs the namespace to build a fully-qualified `ns/test` selector, and the discovery
--- position tree keys tests under the file, not the ns form).
---@param path string
---@return string|nil
local function file_namespace(path)
    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end
    for _, line in ipairs(vim.fn.readfile(path)) do
        -- The ns symbol allows word chars plus . - _ * + ? ! < > = and : (for e.g. my.app.core-test).
        local ns = line:match("%(%s*ns%s+([%w%.%-%_%*%+%?!<>=:]+)")
        if ns then
            return ns
        end
    end
    return nil
end

--- The Clojure-CLI test options (alias + exec-vs-main), with defaults matching the lvim-lang provider.
---@return { alias: string, exec: boolean }
local function clj_opts()
    local a = config.adapters.clojure or {}
    return { alias = a.test_alias or "test", exec = a.test_exec ~= false }
end

---@type LvimTestAdapter
local adapter = {
    name = "clojure",
    filetypes = { "clojure" },
    root_markers = { "deps.edn", "project.clj", "build.boot", "shadow-cljs.edn", ".git" },
    lang = "clojure",
    query = QUERY,
    toolchain_provider = "clojure",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        -- Clojure test namespaces conventionally live under a test/ tree and/or end in `_test`; the
        -- treesitter query surfaces only files that actually contain a deftest, so a slightly wide net
        -- here is harmless. Accept every Clojure source extension.
        return path:match("%.cljc?$") ~= nil or path:match("%.clj$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local tool = detect_tool(root)
        if not tool then
            return nil
        end

        -- Per-file namespace cache (read once), + the result-mapping index (test name → position id).
        local ns_of = {}
        ---@param path string
        ---@return string|nil
        local function ns_for(path)
            if ns_of[path] == nil then
                ns_of[path] = file_namespace(path) or false
            end
            return ns_of[path] or nil
        end

        ---@type table<string, string>  leaf test name → position id
        local by_name = {}
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[pos.name] = pos.id
            end
        end

        -- Collect the selection: fully-qualified vars (specific tests) and namespaces (files/namespaces).
        local vars, var_seen = {}, {}
        local nses, ns_seen = {}, {}
        local function add_var(pos)
            local ns = ns_for(pos.path)
            if ns then
                local v = ns .. "/" .. pos.name
                if not var_seen[v] then
                    var_seen[v] = true
                    vars[#vars + 1] = v
                end
            end
        end
        local function add_ns(path)
            local ns = ns_for(path)
            if ns and not ns_seen[ns] then
                ns_seen[ns] = true
                nses[#nses + 1] = ns
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add_var(t)
            elseif t.kind == "file" then
                add_ns(t.path)
            elseif t.kind == "namespace" then
                add_ns(t.path)
            end -- dir: no filter → run everything
        end

        local a = config.adapters.clojure or {}
        local cmd = { bin(tool == "clj" and "clojure" or tool, root) }
        local co = clj_opts()

        if tool == "lein" then
            cmd[#cmd + 1] = "test"
            if #vars > 0 then
                -- Leiningen selects specific tests with `:only ns/test` (repeatable).
                for _, v in ipairs(vars) do
                    cmd[#cmd + 1] = ":only"
                    cmd[#cmd + 1] = v
                end
            else
                -- Whole namespaces: `lein test ns …` (empty → the whole suite).
                vim.list_extend(cmd, nses)
            end
        elseif tool == "clj" and co.exec then
            -- The Cognitect test-runner exec fn: `-X:<alias> :vars '[…]'` / `:nses '[…]'`.
            cmd[#cmd + 1] = "-X:" .. co.alias
            if #vars > 0 then
                cmd[#cmd + 1] = ":vars"
                cmd[#cmd + 1] = "[" .. table.concat(vars, " ") .. "]"
            elseif #nses > 0 then
                cmd[#cmd + 1] = ":nses"
                cmd[#cmd + 1] = "[" .. table.concat(nses, " ") .. "]"
            end
        elseif tool == "clj" then
            -- A `-M` alias (a plain main): no known selector syntax → run the whole suite.
            cmd[#cmd + 1] = "-M:" .. co.alias
        else -- boot: no standard per-test filter → the whole `boot test` task.
            cmd[#cmd + 1] = "test"
        end

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
        ---@type table<string, { short: string, path?: string, line?: integer, output: string[] }>
        local failed = {}
        local ran = false

        local lines = ctx.lines or {}
        local i = 1
        while i <= #lines do
            local line = lines[i]
            if line:match("^Ran%s+%d+%s+tests?") then
                ran = true
            end
            -- `FAIL in (test-name) (file.clj:12)` / `ERROR in (test-name) (file.clj:12)`.
            local name, file, lnum = line:match("^%u+%s+in%s+%(([^%)]+)%)%s+%(([^:%)]+):(%d+)%)")
            if not name then
                name = line:match("^%u+%s+in%s+%(([^%)]+)%)")
            end
            if name and line:match("^%u+%s+in%s+%(") then
                -- The reported name is the deftest symbol, sometimes `test-name` or a nested testing
                -- label; keep the first token (the deftest) so it maps to a discovered position.
                local leaf = name:match("^%S+") or name
                -- Gather the block (message + expected/actual) up to the next report / blank boundary.
                local block = { line }
                local j = i + 1
                while j <= #lines do
                    local l = lines[j]
                    if l:match("^%u+%s+in%s+%(") or l:match("^Ran%s+%d+") or l:match("^Testing%s") then
                        break
                    end
                    block[#block + 1] = l
                    j = j + 1
                end
                -- A more useful short than the `FAIL in …` header: the first meaningful body line —
                -- the `testing` context label or the `expected:` line — falling back to the header.
                local detail
                for k = 2, #block do
                    local b = vim.trim(block[k])
                    if b ~= "" then
                        detail = b
                        break
                    end
                end
                local existing = failed[leaf]
                local short = (existing and existing.short) or detail or vim.trim(line)
                failed[leaf] = {
                    short = short,
                    path = file and vim.fs.basename(file) or (existing and existing.path),
                    line = lnum and tonumber(lnum) or (existing and existing.line),
                    output = existing and vim.list_extend(existing.output, block) or block,
                }
            end
            i = i + 1
        end

        -- Failing covered tests: mark failed with the file:line diagnostic (resolved to the real path).
        for leaf, info in pairs(failed) do
            local id = c.by_name[leaf]
            if id then
                local res = { status = "failed", short = info.short, output = info.output }
                local pos = (ctx.scope_map or {})[id]
                if pos and info.line then
                    res.errors = { { message = info.short, path = pos.path, line = info.line } }
                end
                out[id] = res
            end
        end

        if ran then
            -- Every covered test that ran and was not reported failed → passed.
            for _, id in ipairs(ctx.covered or {}) do
                if not out[id] then
                    local pos = (ctx.scope_map or {})[id]
                    if pos and pos.kind == "test" then
                        out[id] = { status = "passed" }
                    end
                end
            end
        elseif ctx.exit_code and ctx.exit_code ~= 0 and next(out) == nil then
            -- Nothing ran and the run failed → a compile / require error. Mark the covered files.
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] =
                        { status = "failed", short = "test run failed (compile/require error)", output = lines }
                end
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        local found = vim.fn.exepath("clojure")
        if found == "" then
            found = vim.fn.exepath("lein")
        end
        if found ~= "" then
            h.ok("clojure build tool: " .. found)
        else
            h.warn("no clojure / lein on PATH — install the Clojure CLI or Leiningen")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
