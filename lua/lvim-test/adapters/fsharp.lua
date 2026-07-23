-- lvim-test.adapters.fsharp: the F# / .NET adapter.
-- Discovers test bindings via a treesitter query — a `value_declaration` whose `attributes` carry a
-- test attribute (xUnit `[<Fact>]`/`[<Theory>]`, NUnit `[<Test>]`/`[<TestCase>]`, FsCheck
-- `[<Property>]`) — nested under `namespace`/`named_module`/`module_defn` declarations, and runs them
-- through `dotnet test`. dotnet test has no stable per-test streaming format, so results are taken
-- from the TRX report it writes (`--logger "trx;LogFileName=…"`): the `<TestDefinitions>` map each
-- testId to a `className.name` fully-qualified name and the `<Results>` carry each outcome + failure
-- message, so every discovered position is resolved reliably. A compile failure (no TRX / non-zero
-- exit) marks the covered tests failed with the F# compiler output.
--
-- Test names filter with `--filter "Name~<binding>"` (the VSTest test NAME, not the FQN — F# module
-- functions compile to `Namespace.Module.binding` and backtick-quoted names hold spaces, so the leaf
-- Name is the reliable selector); results map back by the leaf name of each TRX `className.name`.
-- Combinator-style Expecto suites (`testCase "…"` inside a `testList`) are not statically
-- discoverable — run the whole project/dir for those.
--
-- When lvim-lang is installed and its F# provider is active, the `dotnet` binary is resolved through
-- `lvim-lang.core.toolchain` first (honouring a version-managed SDK), then PATH. lvim-test works
-- fully without lvim-lang.
--
---@module "lvim-test.adapters.fsharp"

local config = require("lvim-test.config")

-- Namespaces / modules → `@namespace`; test-attributed bindings → `@test`. The `@_attr` helper capture
-- (no dot in its name) is ignored by the discovery collector; the `#match?` keeps only bindings whose
-- attribute mentions a known test attribute. F# attributed tests bind with `let name () = …`, holding a
-- `function_or_value_defn` — nested in a `declaration_expression` inside a module body, or a
-- `value_declaration` at a namespace's top level; both are matched.
local QUERY = [[
(namespace name: (_) @namespace.name) @namespace.definition
(named_module name: (_) @namespace.name) @namespace.definition
(module_defn (identifier) @namespace.name) @namespace.definition
(value_declaration
  (attributes) @_attr
  (function_or_value_defn
    (function_declaration_left . (_) @test.name))
  (#match? @_attr "Fact|Theory|TestCase|Test|Property")) @test.definition
(declaration_expression
  (attributes) @_attr
  (function_or_value_defn
    (function_declaration_left . (_) @test.name))
  (#match? @_attr "Fact|Theory|TestCase|Test|Property")) @test.definition
]]

local M = {}

--- The `dotnet` binary for a root: the lvim-lang F# toolchain when active, else PATH, else the name.
---@param root string
---@return string
local function dotnet_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("fsharp", "dotnet", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("dotnet")
    return p ~= "" and p or "dotnet"
end

--- A position's leaf test name — the binding name, with backticks stripped (```let ``my test`` () =```
--- renders as `my test` in the compiled test Name).
---@param pos LvimTestPosition
---@return string
local function leaf_name(pos)
    return (pos.name:gsub("`", ""))
end

--- Unescape the five predefined XML entities in a TRX message / stack-trace fragment.
---@param s string
---@return string
local function xml_unescape(s)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

--- Map a TRX `outcome` attribute to a position status.
---@param outcome string
---@return "passed"|"failed"|"skipped"
local function status_of(outcome)
    if outcome == "Passed" then
        return "passed"
    elseif outcome == "Failed" or outcome == "Error" or outcome == "Timeout" then
        return "failed"
    end
    return "skipped" -- NotExecuted / Inconclusive / Aborted / …
end

--- Parse a TRX file into `{ leafName → { status, message?, stack? } }`. Uses the `<TestDefinitions>`
--- (testId → className.name) to resolve every `<Results>` outcome to the test's leaf Name (the F#
--- binding), so it works for xUnit / NUnit / FsCheck alike (a text-pattern parse — TRX has no
--- attribute-order or namespace surprises to defeat it).
---@param trx string  the TRX file contents
---@return table<string, table>  leafName → { status, message?, stack? }
local function parse_trx(trx)
    ---@type table<string, string>  testId → leaf test name
    local name_by_id = {}
    for block in trx:gmatch("<UnitTest%f[%s].-</UnitTest>") do
        local id = block:match('id="(.-)"')
        local tm = block:match("<TestMethod(.-)/>") or block:match("<TestMethod(.-)>")
        if id and tm then
            local method = tm:match('name="(.-)"')
            if method then
                -- The Name can carry parameterised suffixes (`test(x: 1)`); fold onto the base name.
                method = method:gsub("%(.*", "")
                name_by_id[id] = method
            end
        end
    end

    ---@type table<string, { status: string, message?: string, stack?: string }>
    local out = {}
    --- Fold a per-run outcome onto its leaf name (a data row never downgrades a sibling's failure).
    ---@param name string
    ---@param status string
    ---@param message? string
    ---@param stack? string
    local function fold(name, status, message, stack)
        local cur = out[name]
        if not cur then
            out[name] = { status = status, message = message, stack = stack }
            return
        end
        if status == "failed" and cur.status ~= "failed" then
            cur.status = "failed"
            cur.message = message or cur.message
            cur.stack = stack or cur.stack
        elseif cur.status == "skipped" and status == "passed" then
            cur.status = "passed"
        end
    end

    -- Each <UnitTestResult> is either self-closing (passed/skipped) or a container (failure, with an
    -- <ErrorInfo>). A gmatch over `.-</UnitTestResult>` would greedily span a preceding self-closed
    -- element, so slice the document between successive `<UnitTestResult` starts and read each
    -- element's own attributes/message from its segment.
    local starts, init = {}, 1
    while true do
        local s = trx:find("<UnitTestResult", init, true)
        if not s then
            break
        end
        starts[#starts + 1] = s
        init = s + 1
    end
    for i, s in ipairs(starts) do
        local seg = trx:sub(s, (starts[i + 1] and starts[i + 1] - 1) or #trx)
        local id = seg:match('testId="(.-)"')
        local outcome = seg:match('outcome="(.-)"')
        local name = id and name_by_id[id]
        if name and outcome then
            local message = seg:match("<Message>(.-)</Message>")
            local stack = seg:match("<StackTrace>(.-)</StackTrace>")
            fold(name, status_of(outcome), message and xml_unescape(message), stack and xml_unescape(stack))
        end
    end
    return out
end

--- Extract a `path:line` diagnostic from a TRX stack trace (`… in /abs/File.fs:line 42`).
---@param stack string
---@param message? string
---@return { message: string, path?: string, line?: integer }?
local function diag_from_stack(stack, message)
    for _, l in ipairs(vim.split(stack, "\n")) do
        local file, lnum = l:match("in%s+(.-):line%s+(%d+)")
        if file then
            return { message = message or vim.trim(l), path = vim.trim(file), line = tonumber(lnum) }
        end
    end
    return nil
end

---@type LvimTestAdapter
local adapter = {
    name = "fsharp",
    filetypes = { "fsharp" },
    -- `.sln`/`.fsproj` are globs; the registry resolves the root via literal markers, so `.git` is the
    -- reliable literal anchor (a solution/project always lives inside the repo).
    root_markers = { ".git" },
    lang = "fsharp",
    query = QUERY,
    toolchain_provider = "fsharp",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        -- F# tests live in any `.fs`; the treesitter query surfaces only files that hold test bindings.
        -- A cheap name filter still prunes the walk to the conventional test files.
        local tail = vim.fn.fnamemodify(path, ":t")
        return tail:match("%.fs$") ~= nil and (tail:match("[Tt]est") ~= nil or tail:match("[Ss]pec") ~= nil)
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local filters, seen = {}, {}
        ---@type table<string, string>  leaf name → position id
        local by_name = {}

        local function add_filter(name)
            if not seen[name] then
                seen[name] = true
                filters[#filters + 1] = "Name~" .. name
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add_filter(leaf_name(t))
            elseif t.kind == "namespace" then
                -- Every test binding beneath the namespace/module.
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and (pos.id == t.id or (pos.path == t.path)) then
                        add_filter(leaf_name(pos))
                    end
                end
            elseif t.kind == "file" then
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and pos.path == t.path then
                        add_filter(leaf_name(pos))
                    end
                end
            end -- dir: no filter → run the whole project/solution
        end
        -- Map every covered test's leaf name for result resolution.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[leaf_name(pos)] = pos.id
            end
        end

        -- A dedicated results directory so the TRX path is deterministic (default is TestResults/).
        local results_dir = vim.fn.tempname()
        pcall(vim.fn.mkdir, results_dir, "p")
        local trx = results_dir .. "/lvim-test.trx"

        -- Bracket-index the per-adapter block: its field is declared in the shared config once the
        -- adapter is enabled; the defensive `or {}` keeps it working before then.
        local a = config.adapters["fsharp"] or {}
        local cmd = { dotnet_bin(root), "test", "--nologo" }
        if #filters > 0 then
            cmd[#cmd + 1] = "--filter"
            cmd[#cmd + 1] = table.concat(filters, "|")
        end
        cmd[#cmd + 1] = "--logger"
        cmd[#cmd + 1] = "trx;LogFileName=lvim-test.trx"
        cmd[#cmd + 1] = "--results-directory"
        cmd[#cmd + 1] = results_dir
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "typescript", -- F# compiler `file(line,col): error FSxxxx: msg`
            context = { by_name = by_name, trx = trx },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}

        local trx_text
        if c.trx and vim.fn.filereadable(c.trx) == 1 then
            local ok, lines = pcall(vim.fn.readfile, c.trx)
            if ok then
                trx_text = table.concat(lines, "\n")
            end
        end

        if trx_text then
            for name, res in pairs(parse_trx(trx_text)) do
                local id = c.by_name[name]
                if id then
                    local errors
                    if res.status == "failed" then
                        if res.stack then
                            errors = { diag_from_stack(res.stack, res.message) }
                        end
                    end
                    out[id] = {
                        status = res.status,
                        short = res.message and vim.trim((res.message:gsub("\n.*", ""))) or nil,
                        errors = errors and errors[1] and errors or nil,
                    }
                end
            end
            pcall(vim.fn.delete, c.trx)
        end

        -- Compile / restore failure: the run failed and no covered test produced a status → mark the
        -- covered tests failed with the F# compiler output (the `FSxxxx` lines).
        if not next(out) and ctx.exit_code and ctx.exit_code ~= 0 then
            local errors
            for _, l in ipairs(ctx.lines or {}) do
                local file, lnum = l:match("(%S+%.fs)%((%d+),%d+%)")
                if file then
                    errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                    break
                end
            end
            for _, id in ipairs(ctx.covered or {}) do
                out[id] = { status = "failed", short = "build failed", output = ctx.lines, errors = errors }
            end
        end

        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("dotnet") == "" then
            h.warn("dotnet not found on PATH")
        else
            h.ok("dotnet: " .. vim.fn.exepath("dotnet"))
        end
        if not pcall(vim.treesitter.language.inspect, "fsharp") then
            h.warn("fsharp treesitter parser not installed — test discovery needs it")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
