-- lvim-test.adapters.rescript: the rescript adapter.
-- ReScript has no standard test runner; this compiles the project (`rescript build`) as the check. This adapter is SUITE-granular: covered files are marked from the single run's exit
-- code. `rescript` resolves through lvim-lang.core.toolchain when the provider is active, else PATH.
--
---@module "lvim-test.adapters.rescript"

local config = require("lvim-test.config")

---@param root string
---@return string
local function bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local r = tc.resolve("rescript", "rescript", root)
        if r and r ~= "" then
            return r
        end
    end
    local p = vim.fn.exepath("rescript")
    return p ~= "" and p or "rescript"
end

---@type LvimTestAdapter
local adapter = {
    name = "rescript",
    filetypes = { "rescript" },
    lang = "rescript",
    root_markers = { "rescript.json", "bsconfig.json", ".git" },
    toolchain_provider = "rescript",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("_test%.res$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local a = config.adapters.rescript or {}
        local tool = bin(req.root)
        local cmd = { "rescript", "build" }
        cmd[1] = tool
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
        if vim.fn.exepath("rescript") == "" then
            h.warn("rescript not found on PATH")
        else
            h.ok("rescript: " .. vim.fn.exepath("rescript"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
