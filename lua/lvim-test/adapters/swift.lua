-- lvim-test.adapters.swift: the Swift adapter (XCTest, driven through SwiftPM).
-- Discovers XCTestCase test methods via a treesitter query — a `func test…` nested under a
-- `class_declaration` namespace — and runs them through `swift test`. A run filters with one
-- `--filter <Class>/<method>` per requested test (SwiftPM's `--filter` is a regex over
-- `Module.Class/method`); with no target it runs the whole package. `swift test` is not JSON, so
-- results stream from XCTest's console output: `Test Case '…MathTests…testAddition…' passed|failed`
-- flips a position's status live (both the Linux `Class.method` shape and the macOS
-- `-[Module.Class method]` shape are parsed), and the preceding `File.swift:LINE: error: … :
-- message` failure line attaches the message + a diagnostic. A compile failure marks the covered
-- file positions failed.
--
-- Per-test DEBUGGING lives in the lvim-lang Swift provider (`:LvimLang debug-test`), which BUILDS the
-- test bundle first (`swift build --build-tests`) before launching it under lldb-dap — a build step a
-- synchronous DAP config here cannot perform — so this adapter deliberately exposes no `debug`.
--
-- When lvim-lang is installed and its Swift provider is active, the `swift` binary is resolved through
-- `lvim-lang.core.toolchain` first (honouring an explicit SDK / a version manager), then PATH.
-- lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.swift"

local config = require("lvim-test.config")

-- XCTestCase classes → namespaces; `func test…` methods → tests. Nesting is derived from range
-- containment by the discovery engine, so a `test*` method lands under its enclosing class.
local QUERY = [[
(class_declaration
  name: (type_identifier) @namespace.name) @namespace.definition
(function_declaration
  name: (simple_identifier) @test.name
  (#match? @test.name "^test")) @test.definition
]]

local M = {}

--- The `swift` binary for a root: the lvim-lang Swift toolchain when active, else PATH, else the name.
---@param root string
---@return string
local function swift_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("swift", "swift", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("swift")
    return p ~= "" and p or "swift"
end

--- A test position's `<Class>/<method>` filter (its enclosing namespace + its own name), or just the
--- method name for a free `test*` function. This is the name `swift test --filter` selects on, and
--- the shape results map back to.
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function filter_name(map, pos)
    local parent = pos.parent and map[pos.parent]
    if parent and parent.kind == "namespace" then
        return parent.name .. "/" .. pos.name
    end
    return pos.name
end

---@type LvimTestAdapter
local adapter = {
    name = "swift",
    filetypes = { "swift" },
    root_markers = { "Package.swift", ".git" },
    lang = "swift",
    query = QUERY,
    toolchain_provider = "swift",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        -- SwiftPM tests live under a `Tests/` target and are conventionally named `<X>Tests.swift`;
        -- the treesitter query then surfaces only files that actually contain XCTest methods.
        return path:match("[Tt]ests?%.swift$") ~= nil or path:match("/Tests/") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local names, name_seen = {}, {}
        ---@type table<string, string>  "Class/method" → id
        local by_name = {}
        ---@type table<string, string>  leaf method name → id (fallback)
        local by_leaf = {}

        local function add(pos)
            local fn = filter_name(req.scope_map, pos)
            if not name_seen[fn] then
                name_seen[fn] = true
                names[#names + 1] = fn
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add(t)
            elseif t.kind == "namespace" then
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and pos.id:find(t.id, 1, true) == 1 then
                        add(pos)
                    end
                end
            elseif t.kind == "file" then
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and pos.path == t.path then
                        add(pos)
                    end
                end
            end -- dir: no filter → run the whole package
        end
        -- Map EVERY covered test (so streamed lines for siblings still resolve).
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[filter_name(req.scope_map, pos)] = pos.id
                by_leaf[pos.name] = pos.id
            end
        end

        local a = config.adapters.swift or {}
        local cmd = { swift_bin(root), "test" }
        -- One --filter per requested test (each is a regex over Module.Class/method); none → whole package.
        for _, fn in ipairs(names) do
            cmd[#cmd + 1] = "--filter"
            cmd[#cmd + 1] = fn
        end
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "gcc", -- Swift emits clang-style file:line:col: error: message diagnostics
            context = { by_name = by_name, by_leaf = by_leaf, errors = {}, output = {}, build_out = {} },
        }
    end,

    ---@param line string
    ---@param ctx table
    ---@return table<string, LvimTestResult>?
    stream = function(line, ctx)
        local c = ctx.context
        c.build_out[#c.build_out + 1] = line

        -- Failure detail (precedes the summary line): capture path/line/method/message for both the
        -- Linux (`Class.method`) and macOS (`-[Module.Class method]`) shapes.
        local f_path, f_line, f_method, f_msg = line:match("^(.-%.swift):(%d+): error: [%w_]+%.([%w_]+)%s*:%s*(.*)$")
        if not f_path then
            f_path, f_line, f_method, f_msg =
                line:match("^(.-%.swift):(%d+): error: %-%[[%w_.]+%s+([%w_]+)%]%s*:%s*(.*)$")
        end
        if f_path and f_method then
            c.errors[f_method] =
                { message = vim.trim(line), short = vim.trim(f_msg or line), path = f_path, line = tonumber(f_line) }
        end

        -- Live status: `Test Case 'MathTests.testAddition' passed|failed (…)` (Linux) or
        -- `Test Case '-[Module.MathTests testAddition]' passed|failed (…)` (macOS).
        local class, method, result = line:match("Test Case '([%w_]+)%.([%w_]+)' (%a+)")
        if not class then
            class, method, result = line:match("Test Case '%-%[[%w_.]+%.([%w_]+)%s+([%w_]+)%]' (%a+)")
        end
        if class and method and result ~= "started" then
            local id = c.by_name[class .. "/" .. method] or c.by_leaf[method]
            if id then
                if result == "passed" then
                    return { [id] = { status = "passed" } }
                elseif result == "failed" then
                    local e = c.errors[method]
                    return {
                        [id] = {
                            status = "failed",
                            short = e and e.short or "test failed",
                            errors = e and { { message = e.message, path = e.path, line = e.line } } or nil,
                        },
                    }
                end
            end
        end
        return nil
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        -- Streaming produced per-test statuses. Here we only handle a compile / build failure (no
        -- per-test events): mark every covered file position failed with the compiler output, so the
        -- error is visible instead of silently "skipped".
        local produced = false
        for _, id in ipairs(ctx.covered or {}) do
            local r = require("lvim-test.results").get(ctx.root, id)
            if r and (r.status == "passed" or r.status == "failed") then
                produced = true
                break
            end
        end
        if produced or not (ctx.exit_code and ctx.exit_code ~= 0) then
            return {}
        end
        local errors
        for _, l in ipairs(ctx.lines or {}) do
            local file, lnum = l:match("(%S+%.swift):(%d+):%d*:? ")
            if file then
                errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                break
            end
        end
        local out = {}
        for _, pos in pairs(ctx.scope_map or {}) do
            if pos.kind == "file" then
                out[pos.id] = { status = "failed", short = "build failed", output = ctx.lines, errors = errors }
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("swift") == "" then
            h.warn("swift not found on PATH")
        else
            h.ok("swift: " .. vim.fn.exepath("swift"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
