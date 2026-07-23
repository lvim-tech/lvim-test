-- lvim-test.adapters.csharp: the C# / .NET adapter.
-- Discovers test methods via a treesitter query — a `method_declaration` whose attribute list
-- carries a test attribute (xUnit `[Fact]`/`[Theory]`, NUnit `[Test]`/`[TestCase]`, MSTest
-- `[TestMethod]`) — nested under `namespace`/`class` declarations, and runs them through
-- `dotnet test`. dotnet test has no stable per-test streaming format, so results are taken from the
-- TRX report it writes (`--logger "trx;LogFileName=…"`): the `<TestDefinitions>` map each testId to a
-- `className.name` fully-qualified name and the `<Results>` carry each outcome + failure message, so
-- every discovered position is resolved reliably (across all three frameworks), with `[Theory]` data
-- rows folded onto their method. A compile failure (no TRX / non-zero exit) marks the covered tests
-- failed with the C# compiler output.
--
-- Test names are the full `Namespace.Class.Method` path, so a run filters with
-- `--filter "FullyQualifiedName~<path>"`; results map by that path (parameterised `[Theory]` names
-- like `Ns.Class.Method(x: 1)` fold onto `Ns.Class.Method`).
--
-- When lvim-lang is installed and its C# provider is active, the `dotnet` binary is resolved through
-- `lvim-lang.core.toolchain` first (honouring a version-managed SDK), then PATH. lvim-test works
-- fully without lvim-lang.
--
---@module "lvim-test.adapters.csharp"

local config = require("lvim-test.config")

-- Namespaces / classes / records → `@namespace`; test-attributed methods → `@test`. The `@_attr`
-- helper capture (no dot in its name) is ignored by the discovery collector; the `#match?` keeps
-- only methods whose attribute mentions a known test attribute.
local QUERY = [[
(namespace_declaration name: (_) @namespace.name) @namespace.definition
(file_scoped_namespace_declaration name: (_) @namespace.name) @namespace.definition
(class_declaration name: (identifier) @namespace.name) @namespace.definition
(record_declaration name: (identifier) @namespace.name) @namespace.definition
(method_declaration
  (attribute_list (attribute name: (_) @_attr))
  name: (identifier) @test.name
  (#match? @_attr "Fact|Theory|TestMethod|TestCase|Test")) @test.definition
]]

local M = {}

--- The `dotnet` binary for a root: the lvim-lang C# toolchain when active, else PATH, else the name.
---@param root string
---@return string
local function dotnet_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("csharp", "dotnet", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("dotnet")
    return p ~= "" and p or "dotnet"
end

--- A position's fully-qualified name: the namespace/class lineage joined with `.`, then the leaf
--- name — the `Namespace.Class.Method` that `dotnet test` filters and reports on.
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
    return table.concat(parts, ".")
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

--- Parse a TRX file into `{ fqn → { status, message?, stack? } }`. Uses the `<TestDefinitions>`
--- (testId → className.name) to resolve every `<Results>` outcome to a fully-qualified name, so it
--- works for xUnit / NUnit / MSTest alike (a text-pattern parse — TRX has no attribute-order or
--- namespace surprises to defeat it).
---@param trx string  the TRX file contents
---@return table<string, table>  fqn → { status, message?, stack? }
local function parse_trx(trx)
    ---@type table<string, string>  testId → fully-qualified name
    local fqn_by_id = {}
    for block in trx:gmatch("<UnitTest%f[%s].-</UnitTest>") do
        local id = block:match('id="(.-)"')
        local tm = block:match("<TestMethod(.-)/>") or block:match("<TestMethod(.-)>")
        if id and tm then
            local class = tm:match('className="(.-)"')
            local method = tm:match('name="(.-)"')
            if class and method then
                class = class:match("^([^,]+)") or class -- strip `, Assembly, Version=…`
                fqn_by_id[id] = class .. "." .. method
            end
        end
    end

    ---@type table<string, { status: string, message?: string, stack?: string }>
    local out = {}
    --- Fold a per-run outcome onto its fqn (a `[Theory]` row never downgrades a sibling's failure).
    ---@param fqn string
    ---@param status string
    ---@param message? string
    ---@param stack? string
    local function fold(fqn, status, message, stack)
        local cur = out[fqn]
        if not cur then
            out[fqn] = { status = status, message = message, stack = stack }
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
        local fqn = id and fqn_by_id[id]
        if fqn and outcome then
            local message = seg:match("<Message>(.-)</Message>")
            local stack = seg:match("<StackTrace>(.-)</StackTrace>")
            fold(fqn, status_of(outcome), message and xml_unescape(message), stack and xml_unescape(stack))
        end
    end
    return out
end

--- Extract a `path:line` diagnostic from a TRX stack trace (`… in /abs/File.cs:line 42`).
---@param stack string
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
    name = "csharp",
    filetypes = { "cs" },
    -- `.sln`/`.csproj` are globs; the registry resolves the root via literal markers, so `.git` is the
    -- reliable literal anchor (a solution/project always lives inside the repo).
    root_markers = { ".git" },
    lang = "c_sharp",
    query = QUERY,
    toolchain_provider = "csharp",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        -- C# tests live in any `.cs`; the treesitter query surfaces only files that hold test methods.
        -- A cheap name filter still prunes the walk to the conventional test files.
        local tail = vim.fn.fnamemodify(path, ":t")
        return tail:match("%.cs$") ~= nil and (tail:match("[Tt]est") ~= nil or tail:match("[Ss]pec") ~= nil)
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local filters, seen = {}, {}
        ---@type table<string, string>  fully-qualified name → position id
        local by_name = {}

        local function add_filter(fqn)
            if not seen[fqn] then
                seen[fqn] = true
                filters[#filters + 1] = "FullyQualifiedName~" .. fqn
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add_filter(full_name(req.scope_map, t))
            elseif t.kind == "namespace" then
                -- Prefix filter on the namespace/class path — covers every test beneath it.
                add_filter(full_name(req.scope_map, t))
            elseif t.kind == "file" then
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and pos.path == t.path then
                        add_filter(full_name(req.scope_map, pos))
                    end
                end
            end -- dir: no filter → run the whole project/solution
        end
        -- Map every covered test's fully-qualified name for result resolution.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[full_name(req.scope_map, pos)] = pos.id
            end
        end

        -- A dedicated results directory so the TRX path is deterministic (default is TestResults/).
        local results_dir = vim.fn.tempname()
        pcall(vim.fn.mkdir, results_dir, "p")
        local trx = results_dir .. "/lvim-test.trx"

        -- Bracket-index the per-adapter block: its field is declared in the shared config once the
        -- adapter is enabled; the defensive `or {}` keeps it working before then.
        local a = config.adapters["csharp"] or {}
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
            matcher = "typescript", -- C# compiler `file(line,col): error CSxxxx: msg`
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
            for fqn, res in pairs(parse_trx(trx_text)) do
                local id = c.by_name[fqn]
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
        -- covered tests failed with the C# compiler output (the `CSxxxx` lines).
        if not next(out) and ctx.exit_code and ctx.exit_code ~= 0 then
            local errors
            for _, l in ipairs(ctx.lines or {}) do
                local file, lnum = l:match("(%S+%.cs)%((%d+),%d+%)")
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
        if not pcall(vim.treesitter.language.inspect, "c_sharp") then
            h.warn("c_sharp treesitter parser not installed — test discovery needs it")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
