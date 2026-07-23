-- lvim-test.adapters.elm: the elm adapter (elm-test).
-- elm's test command runs the whole suite (no reliable per-test CLI filter), so this adapter is
-- SUITE-granular: covered files are marked from the single run's exit code. `elm-test` resolves through
-- lvim-lang.core.toolchain when the provider is active, else PATH.
--
---@module "lvim-test.adapters.elm"

local config = require("lvim-test.config")

---@param root string
---@return string
local function bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local r = tc.resolve("elm", "elm-test", root)
        if r and r ~= "" then
            return r
        end
    end
    local p = vim.fn.exepath("elm-test")
    return p ~= "" and p or "elm-test"
end

---@type LvimTestAdapter
local adapter = {
    name = "elm",
    filetypes = { "elm" },
    lang = "elm",
    root_markers = { "elm.json", ".git" },
    toolchain_provider = "elm",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("[/\\]tests?[/\\].*%%.elm$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local a = config.adapters.elm or {}
        local tool = bin(req.root)
        local cmd = { tool }
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
        if vim.fn.exepath("elm-test") == "" then
            h.warn("elm-test not found on PATH")
        else
            h.ok("elm-test: " .. vim.fn.exepath("elm-test"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
