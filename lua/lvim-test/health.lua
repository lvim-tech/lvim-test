-- lvim-test.health: :checkhealth lvim-test.
-- Reports the ecosystem dependencies (hard: lvim-tasks / lvim-ui / lvim-utils / lvim-ts; optional:
-- lvim-dap / lvim-lang), the registered adapters + each adapter's own tool check, and the
-- treesitter parser availability for the adapters' languages (so a missing parser is visible
-- before discovery silently returns nothing).
--
---@module "lvim-test.health"

local registry = require("lvim-test.registry")

local M = {}

--- Whether a module is require-able (a dependency is installed).
---@param mod string
---@return boolean
local function has(mod)
    return pcall(require, mod)
end

--- Run the health check.
---@return nil
function M.check()
    local h = vim.health

    h.start("lvim-test dependencies")
    for _, dep in ipairs({ "lvim-tasks", "lvim-ui", "lvim-utils", "lvim-ts" }) do
        if has(dep) then
            h.ok(dep .. " installed")
        else
            h.error(dep .. " NOT installed (required)")
        end
    end
    for _, dep in ipairs({ "lvim-dap", "lvim-lang" }) do
        if has(dep) then
            h.ok(dep .. " installed (optional integration active)")
        else
            h.info(dep .. " not installed (optional: " .. (dep == "lvim-dap" and "debug" or "toolchain") .. ")")
        end
    end

    h.start("lvim-test adapters")
    local names = registry.names()
    if #names == 0 then
        h.warn("no adapters registered (did setup() run?)")
    end
    for _, name in ipairs(names) do
        local adapter = registry.get(name)
        if adapter then
            h.info("adapter: " .. name .. " (" .. table.concat(adapter.filetypes or {}, ", ") .. ")")
            if adapter.health then
                pcall(adapter.health, h)
            end
            local lang = adapter.lang
            if lang then
                local ok_ts, ts = pcall(require, "lvim-ts")
                if ok_ts and ts.missing_for_ft then
                    local missing = ts.missing_for_ft(adapter.filetypes and adapter.filetypes[1] or lang)
                    if missing then
                        h.warn(("treesitter parser '%s' not installed (%s discovery needs it)"):format(missing, name))
                    else
                        h.ok("treesitter parser for " .. name .. " available")
                    end
                end
            end
        end
    end

    h.start("lvim-test debugging (optional)")
    local ok_dap, dap = pcall(require, "lvim-dap")
    if not ok_dap or not dap then
        h.info("lvim-dap not installed — `:LvimTest debug` is unavailable")
    else
        local types = {}
        for _, a in ipairs((dap.list_adapters and dap.list_adapters()) or {}) do
            types[a.type or a.id or a] = true
        end
        -- The built-in adapters' debug configs use these DAP adapter types.
        for _, need in ipairs({ { "go", "go/delve" }, { "dart", "dart" } }) do
            if types[need[1]] then
                h.ok(("DAP adapter '%s' registered (%s debugging)"):format(need[1], need[2]))
            else
                h.info(("DAP adapter '%s' not registered — %s debugging needs it"):format(need[1], need[2]))
            end
        end
    end
end

return M
