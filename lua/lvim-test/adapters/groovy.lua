-- lvim-test.adapters.groovy: the groovy adapter.
-- Groovy tests run through Gradle (`gradle test`) — no per-test CLI filter. This adapter is SUITE-granular: covered files are marked from the single run's exit
-- code. `gradle` resolves through lvim-lang.core.toolchain when the provider is active, else PATH.
--
---@module "lvim-test.adapters.groovy"

local config = require("lvim-test.config")

---@param root string
---@return string
local function bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local r = tc.resolve("groovy", "gradle", root)
        if r and r ~= "" then
            return r
        end
    end
    local p = vim.fn.exepath("gradle")
    return p ~= "" and p or "gradle"
end

---@type LvimTestAdapter
local adapter = {
    name = "groovy",
    filetypes = { "groovy" },
    lang = "groovy",
    root_markers = { "build.gradle", "settings.gradle", ".git" },
    toolchain_provider = "groovy",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("[/\\][Tt]est.*%.groovy$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local a = config.adapters.groovy or {}
        local tool = bin(req.root)
        local cmd = { "gradle", "test" }
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
        if vim.fn.exepath("gradle") == "" then
            h.warn("gradle not found on PATH")
        else
            h.ok("gradle: " .. vim.fn.exepath("gradle"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
