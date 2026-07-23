-- lvim-test.adapters.scala: the Scala (ScalaTest / munit) adapter.
-- Discovers test SUITES (every `class` / `object` / `trait` definition as a namespace) and the common
-- `test("name") { … }` DSL cases (ScalaTest FunSuite, munit) as tests, via a treesitter query, and
-- runs them through the project's build tool: sbt (`testOnly *Suite`) or mill (`__.test`). The project
-- wrapper (`./sbt` / `./mill`) is preferred when present.
--
-- Scala test frameworks are DSL-based and their single-test selectors are framework-specific, so runs
-- are addressed at SUITE (class) granularity — sbt filters to the covered suites with `testOnly`
-- globs; mill has no reliable per-suite filter without a module, so it runs the whole test suite.
-- Individual test STATUSES are recovered from JUnit XML reports at the end (sbt:
-- `target/test-reports/TEST-*.xml`, written by the framework's JUnit reporter; mill:
-- `out/**/test-report.xml`, written by default). Each `<testcase>` maps back onto its position by
-- (simple class name, test name). When no report maps (a plain sbt run without a JUnit reporter), the
-- run's exit code decides: exit 0 marks the covered tests passed, a non-zero exit marks the covered
-- files failed (a compile / test failure) so it is visible rather than silently "skipped".
--
-- When lvim-lang is installed and its Scala provider is active, the system `sbt` / `mill` is resolved
-- through `lvim-lang.core.toolchain` (honouring SDKMAN / a version manager); the wrapper still wins.
-- The build tool is detected independently here, so lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.scala"

local config = require("lvim-test.config")

-- Every class / object / trait definition → a namespace; `test("name") { … }` calls → tests. The
-- outer `call_expression` (the one carrying the body) is the test.definition so its range covers the
-- body; the inner call's string argument is the test name (discover strips the surrounding quotes).
local QUERY = [[
(class_definition
  name: (identifier) @namespace.name) @namespace.definition

(object_definition
  name: (identifier) @namespace.name) @namespace.definition

(trait_definition
  name: (identifier) @namespace.name) @namespace.definition

(call_expression
  function: (call_expression
    function: (identifier) @_fn
    arguments: (arguments (string) @test.name))
  (#eq? @_fn "test")) @test.definition
]]

local M = {}

--- The build tool for a root: "sbt" (`build.sbt`) → "mill" (`build.sc`) → nil.
---@param root string
---@return "sbt"|"mill"|nil
local function detect_tool(root)
    if vim.fn.filereadable(vim.fs.joinpath(root, "build.sbt")) == 1 then
        return "sbt"
    end
    if vim.fn.filereadable(vim.fs.joinpath(root, "build.sc")) == 1 then
        return "mill"
    end
    return nil
end

--- Resolve the system build-tool binary through the lvim-lang Scala toolchain when active, else the
--- bare name (found on PATH at run time). Only used when the project ships no wrapper.
---@param name "sbt"|"mill"
---@param root string
---@return string
local function system_bin(name, root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("scala", name, root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    return name
end

--- The leading argv for a build tool: the project wrapper when it ships (and is executable), else the
--- resolved system binary.
---@param tool "sbt"|"mill"
---@param root string
---@return string[]
local function tool_base(tool, root)
    local wrapper = vim.fs.joinpath(root, tool)
    if vim.fn.executable(wrapper) == 1 then
        return { wrapper }
    end
    return { system_bin(tool, root) }
end

--- A position's outermost enclosing suite (namespace) name, else the file basename without `.scala`.
--- Scala addresses a test by its top-level suite, so the outermost namespace wins.
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function simple_suite(map, pos)
    local suite
    ---@type LvimTestPosition?
    local p = pos
    while p do
        if p.kind == "namespace" then
            suite = p.name
        end
        p = p.parent and map[p.parent]
    end
    return suite or vim.fn.fnamemodify(pos.path, ":t:r")
end

--- Decode the XML entities JUnit reports escape, and collapse to a single line.
---@param s string
---@return string
local function xml_unescape(s)
    s = s:gsub("&#10;", " "):gsub("&#13;", " "):gsub("&#9;", " ")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    return vim.trim((s:gsub("%s+", " ")))
end

--- The JUnit XML report files a run produced under `root`, filtered to those written at/after the run
--- start (so a re-run's reports win and stale ones are ignored).
---@param tool "sbt"|"mill"
---@param root string
---@param since integer  epoch seconds the run started
---@return string[]
local function report_files(tool, root, since)
    local globs
    if tool == "mill" then
        globs = { "out/**/test-report.xml" }
    else
        globs = {
            "target/test-reports/TEST-*.xml",
            "target/test-reports/*.xml",
            "*/target/test-reports/TEST-*.xml",
            "*/target/test-reports/*.xml",
        }
    end
    local files, seen = {}, {}
    for _, g in ipairs(globs) do
        for _, f in ipairs(vim.fn.glob(vim.fs.joinpath(root, g), true, true)) do
            local st = vim.uv.fs_stat(f)
            if not seen[f] and st and st.mtime and st.mtime.sec >= (since - 2) then
                seen[f] = true
                files[#files + 1] = f
            end
        end
    end
    return files
end

--- Parse one JUnit XML report into `{ class=<simple>, name=<test>, status, short?, trace }` rows.
---@param text string
---@return { class: string, name: string, status: string, short?: string, trace: string }[]
local function parse_report(text)
    local rows = {}
    local i = 1
    while true do
        local s = text:find("<testcase", i, true)
        if not s then
            break
        end
        local open_end = text:find(">", s, true)
        if not open_end then
            break
        end
        local opentag = text:sub(s, open_end)
        local name = opentag:match('name="(.-)"')
        local classname = opentag:match('classname="(.-)"') or ""
        local cls = classname:match("[^.]+$") or classname
        local status, short, trace = "passed", nil, ""
        if opentag:sub(-2) == "/>" then
            i = open_end + 1
        else
            local close = text:find("</testcase>", open_end, true) or #text
            local body = text:sub(open_end + 1, close - 1)
            if body:find("<skipped", 1, true) then
                status = "skipped"
            elseif body:find("<failure", 1, true) or body:find("<error", 1, true) then
                status = "failed"
                short = body:match('<failure[^>]-message="(.-)"') or body:match('<error[^>]-message="(.-)"')
                short = short and xml_unescape(short) or nil
                trace = body
            end
            i = close + #"</testcase>"
        end
        if name then
            rows[#rows + 1] =
                { class = xml_unescape(cls), name = xml_unescape(name), status = status, short = short, trace = trace }
        end
    end
    return rows
end

---@type LvimTestAdapter
local adapter = {
    name = "scala",
    filetypes = { "scala" },
    root_markers = { "build.sbt", "build.sc", ".git" },
    lang = "scala",
    query = QUERY,
    toolchain_provider = "scala",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        local tail = vim.fn.fnamemodify(path, ":t")
        return tail:match("Spec%.scala$") ~= nil
            or tail:match("Suite%.scala$") ~= nil
            or tail:match("Test%.scala$") ~= nil
            or tail:match("Tests%.scala$") ~= nil
            or tail:match("Properties%.scala$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local tool = detect_tool(root)
        if not tool then
            return nil
        end

        -- Covered suites (simple class names) → sbt `testOnly *Class` globs; result-mapping indexes.
        local suites, suite_seen = {}, {}
        ---@type table<string, string>  "<SimpleClass>#<test name>" → position id
        local by_case = {}
        ---@type table<string, string>  leaf test name → id (fallback)
        local by_leaf = {}

        local function add_suite(cls)
            if cls and not suite_seen[cls] then
                suite_seen[cls] = true
                suites[#suites + 1] = cls
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add_suite(simple_suite(req.scope_map, t))
            elseif t.kind == "namespace" then
                add_suite(t.name)
            elseif t.kind == "file" then
                local found = false
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "namespace" and pos.path == t.path then
                        add_suite(simple_suite(req.scope_map, pos))
                        found = true
                    end
                end
                if not found then
                    add_suite(vim.fn.fnamemodify(t.path, ":t:r"))
                end
            end -- dir: no filter → run everything
        end
        -- Map EVERY covered test for result resolution.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_case[simple_suite(req.scope_map, pos) .. "#" .. pos.name] = pos.id
                by_leaf[pos.name] = pos.id
            end
        end

        local a = config.adapters.scala or {}
        local cmd = tool_base(tool, root)
        if tool == "sbt" then
            if #suites > 0 then
                -- `testOnly *A *B` is ONE sbt command string.
                local globs = {}
                for _, cls in ipairs(suites) do
                    globs[#globs + 1] = "*" .. cls
                end
                cmd[#cmd + 1] = "testOnly " .. table.concat(globs, " ")
            else
                cmd[#cmd + 1] = "test"
            end
        else -- mill: no reliable per-suite filter without a module → run the whole suite.
            cmd[#cmd + 1] = "__.test"
        end
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "generic",
            context = { tool = tool, by_case = by_case, by_leaf = by_leaf, started = os.time() },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        for _, file in ipairs(report_files(c.tool, ctx.root, c.started)) do
            local text = table.concat(vim.fn.readfile(file), "\n")
            for _, row in ipairs(parse_report(text)) do
                local id = c.by_case[row.class .. "#" .. row.name] or c.by_leaf[row.name]
                if id then
                    local res = { status = row.status }
                    if row.status == "failed" then
                        res.short = row.short or "test failed"
                        res.output = vim.split(row.trace or "", "\n")
                        -- A `File.scala:LINE` from the stack trace → an inline diagnostic.
                        local pos = (ctx.scope_map or {})[id]
                        local tail = pos and vim.fn.fnamemodify(pos.path, ":t")
                        if tail then
                            local lnum = row.trace:match(vim.pesc(tail) .. ":(%d+)")
                            if lnum then
                                res.errors = { { message = res.short, path = pos.path, line = tonumber(lnum) } }
                            end
                        end
                    end
                    out[id] = res
                end
            end
        end

        -- No JUnit report was produced (a plain sbt run without a JUnit reporter): fall back to the
        -- run's exit code. Exit 0 → the covered tests passed; a non-zero exit → mark the covered file
        -- positions failed (a compile / test failure) so it is visible, not silently "skipped".
        if next(out) == nil then
            if ctx.exit_code == 0 then
                for _, pos in pairs(ctx.scope_map or {}) do
                    if pos.kind == "test" then
                        out[pos.id] = { status = "passed" }
                    end
                end
            elseif ctx.exit_code and ctx.exit_code ~= 0 then
                for _, pos in pairs(ctx.scope_map or {}) do
                    if pos.kind == "file" then
                        out[pos.id] = { status = "failed", short = "build / test run failed", output = ctx.lines }
                    end
                end
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return table?
    debug = function(req)
        -- Per-suite debugging is driven by lvim-lang's Scala provider (metals' debug adapter); without
        -- it there is no in-editor debug config to hand back.
        local ok, sdap = pcall(require, "lvim-lang.providers.scala.dap")
        if not ok or type(sdap.spec) ~= "function" then
            return nil
        end
        local t = req.targets[1]
        local path = t and t.path or vim.api.nvim_buf_get_name(0)
        return {
            type = "scala",
            request = "launch",
            name = "lvim-test: " .. (t and t.name or "scala"),
            metals = { runType = "testFile", path = vim.uri_from_fname(path) },
        }
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("sbt") ~= "" or vim.fn.exepath("mill") ~= "" then
            h.ok("build tool: " .. (vim.fn.exepath("sbt") ~= "" and "sbt" or "mill"))
        else
            h.info("no sbt / mill on PATH — a project ./sbt / ./mill wrapper is used when present")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
