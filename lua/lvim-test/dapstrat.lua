-- lvim-test.dapstrat: the DAP debug strategy.
-- Debugs a single test position through lvim-dap: the owning adapter turns the position into a DAP
-- configuration (`adapter.debug`), which lvim-dap launches (breakpoints / stepping as usual). When
-- the debuggee EXITS, its exit code becomes the position's result (0 = passed, else failed) — so a
-- debug run also updates the signs / tree, not just the debugger. lvim-dap is OPTIONAL: without it
-- the command reports cleanly.
--
---@module "lvim-test.dapstrat"

local results = require("lvim-test.results")

local M = {}

---@type { root: string, id: string }?  the position currently being debugged (one at a time)
local pending = nil

---@type boolean  the exit listener is registered once
local wired = false

--- Register the one-shot exit listener that turns a debug session's exit code into a result.
---@param dap table  the lvim-dap module
---@return nil
local function ensure_listener(dap)
    if wired then
        return
    end
    wired = true
    dap.listeners.after.event_exited["lvim-test"] = function(_, body)
        if pending then
            local status = (body and body.exitCode == 0) and "passed" or "failed"
            results.merge(pending.root, { [pending.id] = { status = status } })
            pending = nil
        end
    end
end

--- Debug the position in `req.targets[1]` through lvim-dap.
---@param req LvimTestRunRequest
---@return nil
function M.run(req)
    local ok, dap = pcall(require, "lvim-dap")
    if not ok or not dap then
        vim.notify("lvim-test: lvim-dap is not installed", vim.log.levels.WARN, { title = "lvim-test" })
        return
    end
    local adapter = req.adapter
    if not adapter.debug then
        vim.notify(
            "lvim-test: " .. adapter.name .. " does not support debugging",
            vim.log.levels.WARN,
            { title = "lvim-test" }
        )
        return
    end
    req.positions = req.targets
    local config = adapter.debug(req)
    if not config then
        vim.notify("lvim-test: no debug configuration for this position", vim.log.levels.WARN, { title = "lvim-test" })
        return
    end

    local target = req.targets[1]
    if target and target.kind == "test" then
        results.set_positions(req.root, req.scope_map or { [target.id] = target })
        pending = { root = req.root, id = target.id }
    else
        pending = nil
    end

    ensure_listener(dap)
    dap.run(config)
end

return M
