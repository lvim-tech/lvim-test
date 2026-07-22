-- lvim-test.adapters.python: the Python (pytest) adapter.
-- Discovers `def test_*` functions (and `class Test*` namespaces) via a treesitter query and runs
-- them through `python -m pytest -v`. The verbose reporter prints one line per test —
-- `path::Class::test_name PASSED|FAILED|SKIPPED [ pct% ]` — whose node id is exactly a discovered
-- position's address, so results stream live by node id; the trailing `FAILED path::test - reason`
-- summary + traceback (parsed at the end) attach the short reason + a `file.py:LINE` diagnostic.
--
-- When lvim-lang is installed and its Python provider is active, the interpreter is resolved through
-- `lvim-lang.core.toolchain` first (the project's VIRTUAL ENV), then `python3` / `python` on PATH —
-- so tests run under the same environment the code runs in. lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.python"

local config = require("lvim-test.config")

-- `def test_*` → tests; `class *` → namespaces (pytest collects `Test*` classes; the runner filters).
local QUERY = [[
(class_definition name: (identifier) @namespace.name) @namespace.definition
(function_definition
  name: (identifier) @test.name
  (#lua-match? @test.name "^test")) @test.definition
]]

local M = {}

--- The Python interpreter for a root: the lvim-lang Python toolchain (venv) when active, else
--- `python3` / `python` on PATH, else the bare name.
---@param root string
---@return string
local function python_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("python", "python", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    for _, b in ipairs({ "python3", "python" }) do
        local p = vim.fn.exepath(b)
        if p ~= "" then
            return p
        end
    end
    return "python3"
end

--- A position's pytest NODE ID: the file path relative to the root, then the class lineage and the
--- function name, joined with `::` (e.g. `tests/test_x.py::TestMath::test_add`).
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@param root string
---@return string
local function node_id(map, pos, root)
    local lineage = { pos.name }
    local p = pos.parent and map[pos.parent]
    while p and p.kind == "namespace" do
        table.insert(lineage, 1, p.name)
        p = p.parent and map[p.parent]
    end
    local rel = vim.fs.relpath(root, pos.path) or vim.fn.fnamemodify(pos.path, ":t")
    return rel .. "::" .. table.concat(lineage, "::")
end

---@type LvimTestAdapter
local adapter = {
    name = "python",
    filetypes = { "python" },
    root_markers = { "pyproject.toml", "setup.py", "setup.cfg", "pytest.ini", "tox.ini", ".git" },
    lang = "python",
    query = QUERY,
    toolchain_provider = "python",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        local tail = vim.fn.fnamemodify(path, ":t")
        return tail:match("^test_.*%.py$") ~= nil or tail:match(".*_test%.py$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local args, seen = {}, {}
        ---@type table<string, string>  node id → position id
        local by_node = {}
        ---@type table<string, string>  leaf test name → id (fallback)
        local by_leaf = {}

        local function add_arg(a)
            if not seen[a] then
                seen[a] = true
                args[#args + 1] = a
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" or t.kind == "namespace" then
                add_arg(node_id(req.scope_map, t, root))
            elseif t.kind == "file" then
                add_arg(vim.fs.relpath(root, t.path) or t.path)
            end -- dir: no arg → collect from the root
        end
        -- Map every covered test's node id (+ leaf) for result resolution.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_node[node_id(req.scope_map, pos, root)] = pos.id
                by_leaf[pos.name] = pos.id
            end
        end

        local a = config.adapters.python or {}
        local cmd = { python_bin(root), "-m", "pytest", "-v", "--no-header" }
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, args)
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "pytest",
            context = { by_node = by_node, by_leaf = by_leaf, output = {} },
        }
    end,

    ---@param line string
    ---@param ctx table
    ---@return table<string, LvimTestResult>?
    stream = function(line, ctx)
        local c = ctx.context
        -- `path::Class::test PASSED [ 50%]` — the node id has no spaces.
        local node, status = line:match("^(%S+::%S+)%s+(%u+)")
        if not node then
            return nil
        end
        local id = c.by_node[node] or c.by_leaf[node:match("[^:]+$") or node]
        if not id then
            return nil
        end
        if status == "PASSED" or status == "XPASS" then
            return { [id] = { status = "passed" } }
        elseif status == "SKIPPED" or status == "XFAIL" or status == "DESELECTED" then
            return { [id] = { status = "skipped" } }
        elseif status == "FAILED" or status == "ERROR" then
            return { [id] = { status = "failed" } }
        end
        return nil
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        -- Failure summaries: `FAILED path::test - reason` (the short-test-summary-info section).
        for _, line in ipairs(ctx.lines or {}) do
            local node, reason = line:match("^FAILED%s+(%S+)%s+%-%s+(.*)$")
            if not node then
                node = line:match("^FAILED%s+(%S+)%s*$")
            end
            if not node then
                node = line:match("^ERROR%s+(%S+)")
            end
            if node then
                local id = c.by_node[node] or c.by_leaf[node:match("[^:]+$") or node]
                if id then
                    out[id] = out[id] or { status = "failed" }
                    if reason and reason ~= "" then
                        out[id].short = vim.trim(reason)
                    end
                end
            end
        end
        -- Attach a file:line diagnostic from a traceback line matching the failed position's file.
        for id, res in pairs(out) do
            local pos = (ctx.scope_map or {})[id]
            local tail = pos and vim.fn.fnamemodify(pos.path, ":t")
            if tail then
                for _, line in ipairs(ctx.lines or {}) do
                    local file, lnum = line:match("(%S*" .. vim.pesc(tail) .. "):(%d+):")
                    if file then
                        res.errors =
                            { { message = res.short or "test failed", path = pos.path, line = tonumber(lnum) } }
                        break
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
        local node = node_id(req.scope_map, t, req.root)
        return {
            type = "python",
            name = "lvim-test: " .. t.name,
            request = "launch",
            module = "pytest",
            args = { node, "-v" },
            cwd = req.root,
            console = "integratedTerminal",
            python = python_bin(req.root),
        }
    end,

    ---@param h table
    health = function(h)
        local py = (function()
            for _, b in ipairs({ "python3", "python" }) do
                local p = vim.fn.exepath(b)
                if p ~= "" then
                    return p
                end
            end
            return ""
        end)()
        if py == "" then
            h.warn("python not found on PATH")
        else
            h.ok("python: " .. py)
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
