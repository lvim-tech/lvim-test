-- lvim-test.adapters.dart: the Dart / Flutter adapter.
-- Discovers `test(...)` / `testWidgets(...)` inside `group(...)` blocks via a treesitter query and
-- runs them through the package:test JSON protocol — `flutter test --machine` for a Flutter
-- project, else `dart test --reporter=json` — mapping the streamed events back onto positions live.
-- The protocol reports a test's FULL name (its enclosing group descriptions + its own, space
-- joined), so results map by full name: each position's full name is its namespace lineage.
--
-- When lvim-lang is installed and its Dart provider is active for the root, the `flutter`/`dart`
-- binary is resolved through `lvim-lang.core.toolchain` first (honouring FVM / an explicit SDK),
-- then PATH — the optional composition seam. lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.dart"

local config = require("lvim-test.config")

-- test / testWidgets → a test; group → a namespace. tree-sitter-dart shape: a call is an
-- expression_statement of an identifier followed by a selector carrying the argument list, whose
-- first argument is the string description.
local QUERY = [[
(expression_statement
  (identifier) @_gname (#eq? @_gname "group")
  (selector (argument_part (arguments (argument (string_literal) @namespace.name))))) @namespace.definition

(expression_statement
  (identifier) @_tname (#any-of? @_tname "test" "testWidgets")
  (selector (argument_part (arguments (argument (string_literal) @test.name))))) @test.definition
]]

---@type table<string, boolean>  root → is a Flutter project (cached)
local flutter_cache = {}

local M = {}

--- Whether a root is a Flutter project (pubspec.yaml declares the flutter SDK / dependency).
---@param root string
---@return boolean
local function is_flutter(root)
    if flutter_cache[root] ~= nil then
        return flutter_cache[root]
    end
    local path = root .. "/pubspec.yaml"
    local flag = false
    if vim.fn.filereadable(path) == 1 then
        local content = table.concat(vim.fn.readfile(path), "\n")
        flag = content:match("\n%s*flutter%s*:") ~= nil or content:match("sdk%s*:%s*flutter") ~= nil
    end
    flutter_cache[root] = flag
    return flag
end

--- Resolve the `flutter` or `dart` binary: the lvim-lang Dart toolchain when a provider is active
--- for the root, else PATH, else the bare name.
---@param tool string  "flutter" | "dart"
---@param root string
---@return string
local function bin(tool, root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("dart", tool, root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath(tool)
    return p ~= "" and p or tool
end

--- A position's FULL runner name: its namespace ancestors' names + its own, space joined (the
--- package:test naming — group descriptions then the test description).
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function full_name(map, pos)
    local parts = { pos.name }
    local p = pos.parent and map[pos.parent]
    while p and (p.kind == "namespace") do
        table.insert(parts, 1, p.name)
        p = p.parent and map[p.parent]
    end
    return table.concat(parts, " ")
end

--- Escape a string for a package:test `--name` regex (anchored by the caller).
---@param s string
---@return string
local function rx(s)
    return (s:gsub("[%.%^%$%*%+%-%?%(%)%[%]%{%}%\\|]", "%%%0"):gsub("%%", "\\"))
end

---@type LvimTestAdapter
local adapter = {
    name = "dart",
    filetypes = { "dart" },
    root_markers = { "pubspec.yaml", ".git" },
    lang = "dart",
    query = QUERY,
    toolchain_provider = "dart",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("_test%.dart$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local flutter = is_flutter(root)
        local tool = flutter and "flutter" or "dart"
        local cmd = flutter and { bin("flutter", root), "test", "--machine" }
            or { bin("dart", root), "test", "--reporter=json" }

        local files, file_seen = {}, {}
        local names = {}
        local file_only = false
        ---@type table<string, string>  full name → position id
        local by_fullname = {}

        local function add_file(path)
            if not file_seen[path] then
                file_seen[path] = true
                files[#files + 1] = path
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" or t.kind == "namespace" then
                names[#names + 1] = "^" .. rx(full_name(req.scope_map, t)) .. "$"
                add_file(t.path)
            elseif t.kind == "file" then
                add_file(t.path)
                file_only = true
            elseif t.kind == "dir" then
                file_only = true -- run everything discovered; no name filter, no file list
            end
        end
        -- Map every discovered test's full name → id for result resolution.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_fullname[full_name(req.scope_map, pos)] = pos.id
            end
        end

        if #names > 0 and not file_only then
            for _, n in ipairs(names) do
                vim.list_extend(cmd, { "--name", n })
            end
        end
        for _, f in ipairs(files) do
            cmd[#cmd + 1] = f
        end
        vim.list_extend(cmd, config.adapters.dart.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        -- Suite/dir runs carry no pre-parsed positions (they must not block on a big project), so
        -- results map LAZILY: each test's file is discovered from its `url` on the first event.
        local lazy = false
        for _, t in ipairs(req.targets) do
            if t.kind == "dir" then
                lazy = true
            end
        end

        local env = vim.tbl_extend("force", {}, config.run.env or {}, config.adapters.dart.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            context = {
                by_fullname = by_fullname,
                names_by_tid = {},
                output = {},
                errors = {},
                tool = tool,
                lazy = lazy,
                root = root,
                adapter = req.adapter,
                discovered = {},
            },
        }
    end,

    ---@param line string
    ---@param ctx table
    ---@return table<string, LvimTestResult>?
    stream = function(line, ctx)
        if line == "" or line:sub(1, 1) ~= "[" and line:sub(1, 1) ~= "{" then
            return nil
        end
        local ok, ev = pcall(vim.json.decode, line)
        if not ok or type(ev) ~= "table" or not ev.type then
            return nil
        end
        local c = ctx.context
        if ev.type == "done" then
            -- The package:test protocol's authoritative end-of-run. `flutter test`/`dart test` under
            -- a pty can LINGER past this (flutter_tester children hold the pty open), so the job's own
            -- exit may never fire — signal the run pipeline to finalize + reap now, rather than hang.
            ctx.protocol_done = true
            ctx.protocol_ok = ev.success ~= false
            return nil
        end
        if ev.type == "testStart" and ev.test then
            c.names_by_tid[ev.test.id] = ev.test.name
            -- Lazy (suite) mapping: discover THIS test's file once, from its url, and index its
            -- positions — so a whole-project run maps results without pre-parsing every file.
            if c.lazy and type(ev.test.url) == "string" then
                local file = ev.test.url:gsub("^file://", "")
                if not c.discovered[file] and vim.fn.filereadable(file) == 1 then
                    c.discovered[file] = true
                    local disc = require("lvim-test.discover")
                    local bufnr = vim.fn.bufnr(file)
                    local map = disc.file(c.adapter, file, bufnr ~= -1 and bufnr or nil)
                    require("lvim-test.results").set_positions(c.root, map)
                    for _, pos in pairs(map) do
                        if pos.kind == "test" then
                            c.by_fullname[full_name(map, pos)] = pos.id
                        end
                    end
                end
            end
            return nil
        elseif ev.type == "print" and ev.testID then
            local name = c.names_by_tid[ev.testID]
            local id = name and c.by_fullname[name]
            if id then
                local acc = c.output[id] or {}
                acc[#acc + 1] = ev.message or ""
                c.output[id] = acc
            end
            return nil
        elseif ev.type == "error" and ev.testID then
            local name = c.names_by_tid[ev.testID]
            local id = name and c.by_fullname[name]
            if id then
                local acc = c.errors[id] or {}
                acc[#acc + 1] = { error = ev.error or "", stack = ev.stackTrace or "" }
                c.errors[id] = acc
            end
            return nil
        elseif ev.type == "testDone" and ev.testID then
            if ev.hidden then
                return nil
            end
            local name = c.names_by_tid[ev.testID]
            local id = name and c.by_fullname[name]
            if not id then
                return nil
            end
            if ev.skipped then
                return { [id] = { status = "skipped", output = c.output[id] } }
            end
            if ev.result == "success" then
                return { [id] = { status = "passed", output = c.output[id] } }
            end
            -- failure / error
            local errs = c.errors[id] or {}
            local short, errors
            if errs[1] then
                short = vim.split(errs[1].error, "\n", { plain = true })[1]
                local file, lnum = (errs[1].stack or ""):match("([^%s:]+%.dart):(%d+):")
                if file then
                    errors = { { message = short or "test failed", path = file, line = tonumber(lnum) } }
                end
            end
            return {
                [id] = {
                    status = "failed",
                    output = c.output[id],
                    short = short or "test failed",
                    errors = errors,
                },
            }
        end
        return nil
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        -- Streaming produces every per-test status. A compile/load failure yields no testDone for
        -- the covered positions; run.lua's missing_result resolves those. Nothing to add here.
        return {}
    end,

    ---@param req LvimTestRunRequest
    ---@return table?
    debug = function(req)
        local t = req.targets[1]
        if not t then
            return nil
        end
        return {
            type = "dart",
            name = "lvim-test: " .. t.name,
            request = "launch",
            program = t.path,
            args = { "--plain-name", t.name },
        }
    end,

    ---@param h table
    health = function(h)
        local dart, flutter = vim.fn.exepath("dart"), vim.fn.exepath("flutter")
        if dart == "" and flutter == "" then
            h.warn("neither dart nor flutter found on PATH")
        else
            h.ok("dart: " .. (dart ~= "" and dart or "-") .. "  flutter: " .. (flutter ~= "" and flutter or "-"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
