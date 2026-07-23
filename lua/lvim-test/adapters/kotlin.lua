-- lvim-test.adapters.kotlin: the Kotlin (JUnit / kotlin.test) adapter.
-- Discovers `@Test`-annotated functions (and their enclosing classes / objects as namespaces) via a
-- treesitter query — a `function_declaration` whose `modifiers` carry an annotation whose name
-- contains "Test" (so `@Test`, `@ParameterizedTest`, `@RepeatedTest`, `@TestFactory` all count) —
-- and runs them through the project's build tool: Gradle (`test --tests <pattern>`) or Maven
-- (`test -Dtest=<sel>`), the wrapper (`./gradlew` / `./mvnw`) preferred when present.
--
-- Gradle and Maven do not stream a per-test protocol, but both write JUnit XML reports (Gradle:
-- `build/test-results/test/TEST-*.xml`; Maven: `target/surefire-reports/TEST-*.xml`). So results are
-- parsed at the END from those reports (only files written by THIS run — filtered by mtime): each
-- `<testcase>` maps back onto its position by (simple class name, method), with a `<failure>` /
-- `<error>` giving the short reason + a `File.kt:LINE` diagnostic. There is no live streaming
-- (statuses resolve when the run finishes); a compile failure marks the covered files.
--
-- When lvim-lang is installed and its Kotlin provider is active, the system `gradle` / `mvn` is
-- resolved through `lvim-lang.core.toolchain` (honouring SDKMAN / a version manager); the wrapper
-- still wins. The build tool is detected independently here, so lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.kotlin"

local config = require("lvim-test.config")

-- `@Test`-ish annotated functions → tests; every class / object declaration → a namespace. The
-- Kotlin grammar names a function with a `simple_identifier` and a type with a `type_identifier`; an
-- annotation's name is a `type_identifier`, either directly (`@Test`) or under a
-- `constructor_invocation` (`@RepeatedTest(3)`). `#match? "Test"` keeps only the test annotations.
local QUERY = [[
(class_declaration
  (type_identifier) @namespace.name) @namespace.definition

(object_declaration
  (type_identifier) @namespace.name) @namespace.definition

(function_declaration
  (modifiers
    (annotation
      [
        (user_type (type_identifier) @_ann)
        (constructor_invocation (user_type (type_identifier) @_ann))
      ]))
  (simple_identifier) @test.name
  (#match? @_ann "Test")) @test.definition
]]

-- Gradle project markers (any present → Gradle); otherwise a `pom.xml` → Maven.
local GRADLE_MARKERS = { "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle", "gradlew" }

local M = {}

--- The build tool for a root: "gradle" (a Gradle marker) → "maven" (a `pom.xml`) → nil.
---@param root string
---@return "gradle"|"maven"|nil
local function detect_tool(root)
    for _, marker in ipairs(GRADLE_MARKERS) do
        if vim.fn.filereadable(vim.fs.joinpath(root, marker)) == 1 then
            return "gradle"
        end
    end
    if vim.fn.filereadable(vim.fs.joinpath(root, "pom.xml")) == 1 then
        return "maven"
    end
    return nil
end

--- Resolve the system build-tool binary through the lvim-lang Kotlin toolchain when active, else the
--- bare name (found on PATH at run time). Only used when the project ships no wrapper.
---@param name string  "gradle" | "mvn"
---@param root string
---@return string
local function system_bin(name, root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        -- lvim-lang resolves gradle under the Kotlin provider namespace; `mvn` is not managed there.
        local resolved = name == "gradle" and tc.resolve("kotlin", "gradle", root) or nil
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    return name
end

--- The leading argv for a build tool: the project wrapper when it ships (and is executable), else
--- the resolved system binary.
---@param tool "gradle"|"maven"
---@param root string
---@return string[]
local function tool_base(tool, root)
    local wrapper = vim.fs.joinpath(root, tool == "maven" and "mvnw" or "gradlew")
    if vim.fn.executable(wrapper) == 1 then
        return { wrapper }
    end
    return { system_bin(tool == "maven" and "mvn" or "gradle", root) }
end

--- A position's outermost enclosing class (namespace) name, else the file basename without `.kt`.
--- JUnit addresses a test by its top-level class, so the outermost namespace wins.
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function simple_class(map, pos)
    local cls
    ---@type LvimTestPosition?
    local p = pos
    while p do
        if p.kind == "namespace" then
            cls = p.name
        end
        p = p.parent and map[p.parent]
    end
    return cls or vim.fn.fnamemodify(pos.path, ":t:r")
end

--- Decode the XML entities JUnit reports escape, and collapse to a single line.
---@param s string
---@return string
local function xml_unescape(s)
    s = s:gsub("&#10;", " "):gsub("&#13;", " "):gsub("&#9;", " ")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    return vim.trim((s:gsub("%s+", " ")))
end

--- The JUnit XML report files a run produced under `root`, filtered to those written at/after the
--- run start (so a re-run's reports win and stale ones for non-rerun classes are ignored).
---@param tool "gradle"|"maven"
---@param root string
---@param since integer  epoch seconds the run started
---@return string[]
local function report_files(tool, root, since)
    local globs
    if tool == "maven" then
        globs = { "target/surefire-reports/TEST-*.xml", "*/target/surefire-reports/TEST-*.xml" }
    else
        globs = { "build/test-results/test/TEST-*.xml", "*/build/test-results/test/TEST-*.xml" }
    end
    local files = {}
    for _, g in ipairs(globs) do
        for _, f in ipairs(vim.fn.glob(vim.fs.joinpath(root, g), true, true)) do
            local st = vim.uv.fs_stat(f)
            if st and st.mtime and st.mtime.sec >= (since - 2) then
                files[#files + 1] = f
            end
        end
    end
    return files
end

--- Parse one JUnit XML report into `{ class=<simple>, name=<method>, status, short?, trace? }` rows.
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
            -- JUnit escapes the classname/name attributes too (a backtick method name is fine, but
            -- entities like &amp; are not); decode them so the discovered name matches.
            rows[#rows + 1] =
                { class = xml_unescape(cls), name = xml_unescape(name), status = status, short = short, trace = trace }
        end
    end
    return rows
end

---@type LvimTestAdapter
local adapter = {
    name = "kotlin",
    filetypes = { "kotlin" },
    root_markers = {
        "build.gradle.kts",
        "build.gradle",
        "settings.gradle.kts",
        "settings.gradle",
        "pom.xml",
        ".git",
    },
    lang = "kotlin",
    query = QUERY,
    toolchain_provider = "kotlin",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        local tail = vim.fn.fnamemodify(path, ":t")
        return tail:match("Test%.kt$") ~= nil
            or tail:match("Tests%.kt$") ~= nil
            or tail:match("IT%.kt$") ~= nil
            or tail:match("^Test.*%.kt$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local tool = detect_tool(root)
        if not tool then
            return nil
        end

        -- Run filters (which tests to select) + the result-mapping indexes.
        local filters, filt_seen = {}, {}
        ---@type table<string, string>  "<SimpleClass>#<method>" → position id
        local by_case = {}
        ---@type table<string, string>  leaf method name → id (fallback)
        local by_leaf = {}

        local function add_filter(cls, method)
            local key
            if tool == "gradle" then
                key = method and ("*" .. cls .. "." .. method) or ("*" .. cls)
            else
                key = method and (cls .. "#" .. method) or cls
            end
            if not filt_seen[key] then
                filt_seen[key] = true
                filters[#filters + 1] = key
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add_filter(simple_class(req.scope_map, t), t.name)
            elseif t.kind == "namespace" then
                add_filter(t.name, nil)
            elseif t.kind == "file" then
                local classes = {}
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "namespace" and pos.path == t.path then
                        classes[simple_class(req.scope_map, pos)] = true
                    end
                end
                if not next(classes) then
                    classes[vim.fn.fnamemodify(t.path, ":t:r")] = true
                end
                for cls in pairs(classes) do
                    add_filter(cls, nil)
                end
            end -- dir: no filter → run everything
        end
        -- Map EVERY covered test for result resolution.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_case[simple_class(req.scope_map, pos) .. "#" .. pos.name] = pos.id
                by_leaf[pos.name] = pos.id
            end
        end

        local a = config.adapters.kotlin or {}
        local cmd = tool_base(tool, root)
        if tool == "gradle" then
            cmd[#cmd + 1] = "test"
            for _, f in ipairs(filters) do
                cmd[#cmd + 1] = "--tests"
                cmd[#cmd + 1] = f
            end
        else
            cmd[#cmd + 1] = "test"
            if #filters > 0 then
                cmd[#cmd + 1] = "-Dtest=" .. table.concat(filters, ",")
            end
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
                        -- A `File.kt:LINE` from the stack trace → an inline diagnostic.
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

        -- No report mapped to a covered test and the run failed → a compile/config failure. Mark the
        -- covered file positions failed so the error is visible instead of silently "skipped".
        if next(out) == nil and ctx.exit_code and ctx.exit_code ~= 0 then
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] = { status = "failed", short = "build / test run failed", output = ctx.lines }
                end
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return table?
    debug = function(req)
        -- Per-test debugging is driven by lvim-lang's Kotlin provider (kotlin-debug-adapter); without
        -- it there is no in-editor debug config to hand back.
        local ok, kdap = pcall(require, "lvim-lang.providers.kotlin.dap")
        if not ok or type(kdap.spec) ~= "function" then
            return nil
        end
        local t = req.targets[1]
        return {
            type = "kotlin",
            request = "attach",
            name = "lvim-test: " .. (t and t.name or "kotlin"),
            hostName = "127.0.0.1",
            port = 5005,
        }
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("gradle") ~= "" or vim.fn.exepath("mvn") ~= "" then
            h.ok("build tool: " .. (vim.fn.exepath("gradle") ~= "" and "gradle" or "mvn"))
        else
            h.info("no gradle / mvn on PATH — a project ./gradlew / ./mvnw wrapper is used when present")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
