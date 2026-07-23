-- lvim-test.adapters.gleam: the gleam adapter (gleam).
-- gleam's test command runs the whole suite (no reliable per-test CLI filter), so this adapter is
-- SUITE-granular: covered files are marked from the single run's exit code. `gleam` resolves through
-- lvim-lang.core.toolchain when the provider is active, else PATH.
--
---@module "lvim-test.adapters.gleam"

local config = require("lvim-test.config")

---@param root string
---@return string
local function bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local r = tc.resolve("gleam", "gleam", root)
        if r and r ~= "" then
            return r
        end
    end
    local p = vim.fn.exepath("gleam")
    return p ~= "" and p or "gleam"
end

---@type LvimTestAdapter
local adapter = {
    name = "gleam",
    filetypes = { "gleam" },
    lang = "gleam",
    root_markers = { "gleam.toml", ".git" },
    toolchain_provider = "gleam",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("_test%%.gleam$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local a = config.adapters.gleam or {}
        local tool = bin(req.root)
        local cmd = { tool, "test" }
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
        if vim.fn.exepath("gleam") == "" then
            h.warn("gleam not found on PATH")
        else
            h.ok("gleam: " .. vim.fn.exepath("gleam"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
