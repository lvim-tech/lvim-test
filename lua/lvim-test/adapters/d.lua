-- lvim-test.adapters.d: the D adapter (dub test).
-- D's `unittest { … }` blocks are ANONYMOUS and are compiled together into the test build — there is no
-- per-unittest or per-file run, only `dub test` for the whole project. So this adapter is SUITE-granular:
-- any covered D file is marked from the single `dub test` outcome (exit 0 → passed, non-zero → failed).
--
-- When lvim-lang is installed and its D provider is active, `dub` is resolved through
-- `lvim-lang.core.toolchain` first, then PATH. lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.d"

local config = require("lvim-test.config")

--- The `dub` binary for a root: the lvim-lang D toolchain when active, else PATH.
---@param root string
---@return string
local function dub_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("d", "dub", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("dub")
    return p ~= "" and p or "dub"
end

---@type LvimTestAdapter
local adapter = {
    name = "d",
    filetypes = { "d" },
    lang = "d",
    root_markers = { "dub.json", "dub.sdl", ".git" },
    toolchain_provider = "d",
    -- No treesitter query: D unittests are anonymous and only run as a whole via `dub test`.

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("%.d$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local a = config.adapters.d or {}
        local cmd = { dub_bin(root), "test" }
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})
        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local out = {}
        local failed = ctx.exit_code and ctx.exit_code ~= 0
        -- Suite granularity: mark every covered file position from the single dub test outcome.
        for _, pos in pairs(ctx.scope_map or {}) do
            if pos.kind == "file" then
                out[pos.id] = { status = failed and "failed" or "passed", output = failed and ctx.lines or nil }
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("dub") == "" then
            h.warn("dub not found on PATH")
        else
            h.ok("dub: " .. vim.fn.exepath("dub"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
