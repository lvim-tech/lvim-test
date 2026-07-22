-- lvim-test.consumers.output: a per-test output float.
-- Shows one position's captured output (or its one-line short summary) in the canonical read-only
-- info window — the human view of WHY a test passed/failed, separate from the full-run terminal
-- (the lvim-tasks panel). Also drives `open_on_fail`: after a run finishes with failures, the
-- first failed position's output opens automatically (short or full per config).
--
---@module "lvim-test.consumers.output"

local config = require("lvim-test.config")
local registry = require("lvim-test.registry")
local discover = require("lvim-test.discover")
local position = require("lvim-test.position")
local results = require("lvim-test.results")

local M = {}

--- Open the info float for a position's result.
---@param root string
---@param id string
---@param mode "short"|"full"
---@return nil
function M.show(root, id, mode)
    local res = results.get(root, id)
    local pos = results.position(root, id)
    local title = (pos and pos.name) or id
    local lines
    if not res then
        lines = { "(no result — run the test first)" }
    elseif mode == "short" then
        lines = { res.short or ("status: " .. res.status) }
    else
        lines = res.output and #res.output > 0 and vim.deepcopy(res.output)
            or { res.short or ("status: " .. res.status), "(no captured output)" }
    end
    require("lvim-ui").info(lines, {
        title = title,
        hide_cursor = true,
        wrap = true,
    })
end

--- Show the output of the nearest test at the cursor (else the file's first test).
---@param mode "short"|"full"
---@return nil
function M.show_nearest(mode)
    local bufnr = vim.api.nvim_get_current_buf()
    local adapter, root = registry.for_buffer(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if not adapter or not root or not adapter.is_test_file(path, root) then
        vim.notify("lvim-test: not a test file", vim.log.levels.WARN, { title = "lvim-test" })
        return
    end
    local map = discover.file(adapter, path, bufnr)
    local cur = vim.api.nvim_win_get_cursor(0)
    local pos = position.nearest(map, path, cur[1] - 1, cur[2])
    if not pos then
        -- fall back to the first test in the file with a result
        for _, p in pairs(map) do
            if p.kind == "test" and results.get(root, p.id) then
                pos = p
                break
            end
        end
    end
    if not pos then
        vim.notify("lvim-test: no test result here", vim.log.levels.INFO, { title = "lvim-test" })
        return
    end
    M.show(root, pos.id, mode)
end

--- After a completed run with failures, auto-open the first failed position's output per
--- `config.output.open_on_fail` ("short" | "full" | false).
---@param root string
---@return nil
function M.on_run_failed(root)
    local mode = config.output.open_on_fail
    if mode ~= "short" and mode ~= "full" then
        return
    end
    ---@cast mode "short"|"full"
    for id, res in pairs(results.for_root(root)) do
        if res.status == "failed" then
            M.show(root, id, mode)
            return
        end
    end
end

return M
