-- lvim-test.consumers.jump: cursor motions over test positions in a buffer.
-- Jump to the next / previous test (optionally only FAILED ones), so a run's failures are
-- walkable straight from the editor. Positions come from the buffer's cached discovery; failure
-- filtering reads the results store. Pure navigation — it moves the cursor, nothing else.
--
---@module "lvim-test.consumers.jump"

local registry = require("lvim-test.registry")
local discover = require("lvim-test.discover")
local results = require("lvim-test.results")

local M = {}

--- The current buffer's test positions, sorted by start row.
---@param bufnr integer
---@return LvimTestPosition[] positions
---@return string? root
local function buffer_tests(bufnr)
    local adapter, root = registry.for_buffer(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if not adapter or not root or path == "" or not adapter.is_test_file(path, root) then
        return {}, nil
    end
    local map = discover.file(adapter, path, bufnr)
    local list = {}
    for _, pos in pairs(map) do
        if pos.kind == "test" and pos.range then
            list[#list + 1] = pos
        end
    end
    table.sort(list, function(a, b)
        return a.range[1] < b.range[1]
    end)
    return list, root
end

--- Jump to the next/previous test position from the cursor.
---@param dir "next"|"prev"
---@param failed_only boolean  restrict to positions whose last result is "failed"
---@return nil
function M.jump(dir, failed_only)
    local bufnr = vim.api.nvim_get_current_buf()
    local list, root = buffer_tests(bufnr)
    if #list == 0 then
        return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-based
    local ordered = list
    if dir == "prev" then
        ordered = {}
        for i = #list, 1, -1 do
            ordered[#ordered + 1] = list[i]
        end
    end
    for _, pos in ipairs(ordered) do
        local past = dir == "next" and pos.range[1] > row or pos.range[1] < row
        local ok_fail = not failed_only
            or (
                root
                and (function()
                    local r = results.get(root, pos.id)
                    return r and r.status == "failed"
                end)()
            )
        if past and ok_fail then
            vim.api.nvim_win_set_cursor(0, { pos.range[1] + 1, pos.range[2] })
            vim.cmd("normal! zz")
            return
        end
    end
    vim.notify(
        "lvim-test: no " .. (failed_only and "failed test" or "test") .. " " .. dir,
        vim.log.levels.INFO,
        { title = "lvim-test" }
    )
end

return M
