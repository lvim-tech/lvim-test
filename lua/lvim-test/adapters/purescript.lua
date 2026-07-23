-- lvim-test.adapters.purescript: the purescript adapter (spago).
-- purescript's test command runs the whole suite (no reliable per-test CLI filter), so this adapter is
-- SUITE-granular: covered files are marked from the single run's exit code. `spago` resolves through
-- lvim-lang.core.toolchain when the provider is active, else PATH.
--
---@module "lvim-test.adapters.purescript"

local config = require("lvim-test.config")

---@param root string
---@return string
local function bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local r = tc.resolve("purescript", "spago", root)
        if r and r ~= "" then
            return r
        end
    end
    local p = vim.fn.exepath("spago")
    return p ~= "" and p or "spago"
end

---@type LvimTestAdapter
local adapter = {
    name = "purescript",
    filetypes = { "purescript" },
    lang = "purescript",
    root_markers = { "spago.yaml", "spago.dhall", ".git" },
    toolchain_provider = "purescript",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("[/\\][Tt]est[/\\].*%%.purs$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local a = config.adapters.purescript or {}
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
        if vim.fn.exepath("spago") == "" then
            h.warn("spago not found on PATH")
        else
            h.ok("spago: " .. vim.fn.exepath("spago"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
