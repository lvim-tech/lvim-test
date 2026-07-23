-- lvim-test.adapters.grain: the grain adapter.
-- Grain has no standard test runner; this runs the file (`grain run <file>`) as the check. This adapter is SUITE-granular: covered files are marked from the single run's exit
-- code. `grain` resolves through lvim-lang.core.toolchain when the provider is active, else PATH.
--
---@module "lvim-test.adapters.grain"

local config = require("lvim-test.config")

---@param root string
---@return string
local function bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local r = tc.resolve("grain", "grain", root)
        if r and r ~= "" then
            return r
        end
    end
    local p = vim.fn.exepath("grain")
    return p ~= "" and p or "grain"
end

---@type LvimTestAdapter
local adapter = {
    name = "grain",
    filetypes = { "grain" },
    lang = "grain",
    root_markers = { ".git" },
    toolchain_provider = "grain",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("%.test%.gr$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local a = config.adapters.grain or {}
        local tool = bin(req.root)
        local cmd = { "grain", "run" }
        cmd[1] = tool
        for _, t in ipairs(req.targets or {}) do
            if t.path then
                cmd[#cmd + 1] = t.path
            end
        end
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})
        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return { cmd = cmd, cwd = req.root, env = next(env) and env or nil }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local out = {}
        local failed = ctx.exit_code and ctx.exit_code ~= 0
        for _, pos in pairs(ctx.scope_map or {}) do
            if pos.kind == "file" then
                out[pos.id] = { status = failed and "failed" or "passed", output = failed and ctx.lines or nil }
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("grain") == "" then
            h.warn("grain not found on PATH")
        else
            h.ok("grain: " .. vim.fn.exepath("grain"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
