-- lvim-test.adapters.cpp: the C / C++ adapter (GoogleTest + Catch2, driven through CTest).
-- Discovers GoogleTest (`TEST` / `TEST_F` / `TEST_P`) and Catch2 (`TEST_CASE` / `SCENARIO`) tests with
-- a treesitter query (a custom `discover`, because the CTest name is COMPOSED — GoogleTest joins the
-- suite + name as "Suite.Name", Catch2 uses the case string, and `SCENARIO` registers as
-- "Scenario: <name>"). Runs them through `ctest -R "^(…)$" --output-on-failure` in the build dir — the
-- one framework-agnostic runner that works whenever a project registers its tests with CTest
-- (`gtest_discover_tests` / `catch_discover_tests` / `add_test`). Results stream from CTest's console
-- summary (`Test #N: <name> … Passed|***Failed`), which maps 1:1 onto the composed names; the
-- `--output-on-failure` block after a failed summary line becomes that test's output + a
-- `file:line` diagnostic.
--
-- LIMITATIONS (documented, not bugs): mapping assumes the CTest test name equals the composed name —
-- true for the standard `gtest_discover_tests` / `catch_discover_tests` registration. Parameterised
-- GoogleTest (`TEST_P`, registered as `Suite/Inst.Name/0`) and manual `add_test` with custom names
-- fall back to file-level running (a whole-file run has no `-R` filter, so those still run — they just
-- do not map to a per-test position). Pure-C frameworks (Unity / cmocka) are out of scope.
--
---@module "lvim-test.adapters.cpp"

local config = require("lvim-test.config")
local position = require("lvim-test.position")
local results = require("lvim-test.results")

local ts = vim.treesitter

-- GoogleTest `TEST*(Suite, Name) { … }` (a function_definition) + Catch2 `TEST_CASE("x")` /
-- `SCENARIO("x")` (a call_expression whose body is a sibling block, not a child). The helper captures
-- feed the name composition in `discover`.
local QUERY = [[
(function_definition
  declarator: (function_declarator
    declarator: (identifier) @_macro
    parameters: (parameter_list
      (parameter_declaration (type_identifier) @_suite)
      (parameter_declaration (type_identifier) @_name)))
  (#match? @_macro "^TEST")) @test.definition

(expression_statement
  (call_expression
    function: (identifier) @_fn
    arguments: (argument_list . (string_literal (string_content) @_str)))
  (#match? @_fn "^(TEST_CASE|SCENARIO)$")) @test.definition
]]

--- Escape a CTest ERE (`-R`): backslash every metacharacter so the composed `^<name>$` matches the
--- test name literally (GoogleTest's `.`, Catch2's `[tags]`, spaces).
---@param s string
---@return string
local function ere_escape(s)
    return (s:gsub("[%.%^%$%*%+%?%(%)%[%]%{%}%\\|]", "\\%0"))
end

--- The `ctest` binary for a root: the lvim-lang C/C++ toolchain when active, else PATH, else the name.
--- (ctest ships with cmake; the cpp provider resolves cmake, and ctest lives beside it on PATH.)
---@param _root string
---@return string
local function ctest_bin(_root)
    local a = config.adapters.cpp or {}
    if a.ctest_path and vim.fn.executable(a.ctest_path) == 1 then
        return a.ctest_path
    end
    local p = vim.fn.exepath("ctest")
    return p ~= "" and p or "ctest"
end

---@type LvimTestAdapter
local adapter = {
    name = "cpp",
    filetypes = { "c", "cpp", "objc", "objcpp" },
    root_markers = { "CMakeLists.txt", ".git" },
    -- Test frameworks are C++; pin the cpp parser so even a `.c` test file discovers correctly.
    lang = "cpp",
    toolchain_provider = "cpp",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        if
            not path:match("%.cpp$")
            and not path:match("%.cc$")
            and not path:match("%.cxx$")
            and not path:match("%.c$")
        then
            return false
        end
        local base = (path:match("[^/]+$") or path):lower()
        if base:find("test", 1, true) then
            return true
        end
        return path:lower():match("/tests?/") ~= nil
    end,

    --- Custom discovery: run the query and COMPOSE the CTest name for each test (stored in
    --- `data.run`), because a query capture cannot join the suite + name / add the `Scenario:` prefix.
    ---@param ctx LvimTestDiscoverCtx
    ---@return LvimTestPosition[]
    discover = function(ctx)
        local ok_q, query = pcall(ts.query.parse, ctx.lang, QUERY)
        if not ok_q or not query then
            return {}
        end
        local parser
        if type(ctx.source) == "number" then
            parser = ts.get_parser(ctx.source, ctx.lang)
        else
            parser = ts.get_string_parser(ctx.source, ctx.lang)
        end
        if not parser then
            return {}
        end
        local tree = (parser:parse() or {})[1]
        if not tree then
            return {}
        end

        local out = {}
        for _, match in query:iter_matches(tree:root(), ctx.source, 0, -1) do
            local caps, defnode = {}, nil
            for id, nodes in pairs(match) do
                local cap = query.captures[id]
                local node = type(nodes) == "table" and nodes[#nodes] or nodes
                if cap == "test.definition" then
                    defnode = node
                else
                    caps[cap] = ts.get_node_text(node, ctx.source)
                end
            end
            if defnode then
                local display, run
                if caps._macro then -- GoogleTest: Suite.Name
                    if caps._suite and caps._name then
                        run = caps._suite .. "." .. caps._name
                        display = run
                    end
                elseif caps._fn then -- Catch2: the case string ("Scenario: …" for SCENARIO)
                    local s = caps._str or "?"
                    display = s
                    run = caps._fn == "SCENARIO" and ("Scenario: " .. s) or s
                end
                if run then
                    local sr, sc, er, ec = defnode:range()
                    -- Catch2 does not nest the `{ }` block under the macro call — the definition node
                    -- is the `expression_statement`, so its own next sibling is the body block. Extend
                    -- the range over it so cursor-nearest covers the body.
                    if caps._fn then
                        local body = defnode:next_named_sibling()
                        if body and body:type() == "compound_statement" then
                            local _, _, ber, bec = body:range()
                            er, ec = ber, bec
                        end
                    end
                    local id = position.id(ctx.path, display)
                    out[#out + 1] = {
                        id = id,
                        kind = "test",
                        name = display,
                        path = ctx.path,
                        range = { sr, sc, er, ec },
                        parent = ctx.path,
                        children = {},
                        data = { run = run },
                    }
                end
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local names, name_seen = {}, {}
        ---@type table<string, string>  CTest run name → position id (for result mapping)
        local by_name = {}
        local run_all = false

        local function add(pos)
            local run = (pos.data and pos.data.run) or pos.name
            if not name_seen[run] then
                name_seen[run] = true
                names[#names + 1] = run
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add(t)
            elseif t.kind == "file" or t.kind == "namespace" then
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and (t.kind == "namespace" or pos.path == t.path) then
                        add(pos)
                    end
                end
            else -- dir: no `-R` filter → run the whole suite
                run_all = true
            end
        end
        -- Map EVERY covered test name (so streamed lines for siblings still resolve).
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[(pos.data and pos.data.run) or pos.name] = pos.id
            end
        end

        local a = config.adapters.cpp or {}
        local build_dir = a.build_dir or "build"
        local cmd = { ctest_bin(root), "--test-dir", build_dir, "--output-on-failure" }
        if not run_all and #names > 0 then
            local escaped = {}
            for _, n in ipairs(names) do
                escaped[#escaped + 1] = ere_escape(n)
            end
            cmd[#cmd + 1] = "-R"
            cmd[#cmd + 1] = "^(" .. table.concat(escaped, "|") .. ")$"
        end
        vim.list_extend(cmd, a.ctest_args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "gcc",
            context = { by_name = by_name, output = {}, cur = nil },
        }
    end,

    ---@param line string
    ---@param ctx table
    ---@return table<string, LvimTestResult>?
    stream = function(line, ctx)
        local c = ctx.context
        -- CTest summary line: `<i>/<n> Test #<k>: <name> .......   Passed|***Failed   <t> sec`.
        local name = line:match("Test%s+#%d+:%s+(.-)%s+%.%.+")
        if name then
            local id = c.by_name[name]
            c.cur = nil
            if not id then
                return nil
            end
            if line:find("%*%*%*Skipped") or line:find("Not Run") or line:find("Disabled") then
                return { [id] = { status = "skipped" } }
            elseif line:find("Passed") then
                return { [id] = { status = "passed" } }
            end
            -- ***Failed / ***Timeout / ***Exception: start accumulating this test's failure block.
            c.cur = id
            c.output[id] = {}
            return { [id] = { status = "failed" } }
        end
        -- A `Start N:` line ends the previous test's failure block.
        if line:match("^%s*Start%s+%d+:") then
            c.cur = nil
            return nil
        end
        if c.cur then
            local acc = c.output[c.cur]
            acc[#acc + 1] = line
        end
        return nil
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        for id, lines in pairs(c.output) do
            local short, errors
            for _, l in ipairs(lines) do
                local file, lnum = l:match("(%S+):(%d+): Failure") -- GoogleTest
                if not file then
                    file, lnum = l:match("(%S+):(%d+): FAILED") -- Catch2
                end
                if not file then
                    file, lnum = l:match("(%S+%.%a+):(%d+)") -- generic file:line
                end
                if file and not errors then
                    errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                end
                if not short then
                    local t = vim.trim(l)
                    if t ~= "" and not t:match("^%[") and not t:match("^Running main") and not t:match("^Note:") then
                        short = t
                    end
                end
            end
            out[id] = { status = "failed", output = lines, short = short or "test failed", errors = errors }
        end

        -- No per-test result and the run failed → a configure / build error (e.g. no CTest test file,
        -- an un-built tree). Mark the covered file positions failed with the CTest output.
        local produced = false
        for _, id in ipairs(ctx.covered or {}) do
            local r = results.get(ctx.root, id)
            if r and (r.status == "passed" or r.status == "failed") then
                produced = true
                break
            end
        end
        if not produced and next(c.output) == nil and ctx.exit_code and ctx.exit_code ~= 0 then
            local msg = ctx.lines or {}
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] = {
                        status = "failed",
                        short = "ctest failed — is the project configured & built?",
                        output = msg,
                    }
                end
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("ctest") == "" then
            h.warn("ctest not found on PATH (ships with CMake)")
        else
            h.ok("ctest: " .. vim.fn.exepath("ctest"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
