-- lvim-test.watch: re-run watched tests on save.
-- A position is added to its root's WATCHED set (`toggle`); after that, saving a file under the
-- root re-runs the watched positions (debounced) as TRANSIENT runs — they land in the results
-- store (signs / tree update) but stay out of the durable task history and don't pop the panel.
-- `scope` narrows what a save triggers: "project" (any write under the root) or "file" (only
-- writes to a watched position's own file).
--
-- The summary tree reads `is_watching` to badge the watched rows; toggling fires the results event
-- so those badges repaint.
--
---@module "lvim-test.watch"

local config = require("lvim-test.config")
local discover = require("lvim-test.discover")
local run = require("lvim-test.run")

local M = {}

---@type table<string, table<string, LvimTestPosition>>  root → (id → watched position)
local watched = {}

---@type table<string, LvimTestAdapter>  root → the adapter that owns it
local adapters = {}

---@type table<string, uv.uv_timer_t>  root → debounce timer
local timers = {}

--- Fire the results event for a root so consumers (the tree's watch badges) repaint.
---@param root string
---@return nil
local function ping(root)
    vim.api.nvim_exec_autocmds("User", { pattern = "LvimTestResults", data = { root = root, ids = {} } })
end

--- Whether a position id is watched under a root.
---@param root string
---@param id string
---@return boolean
function M.is_watching(root, id)
    return (watched[root] or {})[id] ~= nil
end

--- Toggle watching a position; returns the new watched state.
---@param root string
---@param adapter LvimTestAdapter
---@param pos LvimTestPosition
---@return boolean watching
function M.toggle(root, adapter, pos)
    watched[root] = watched[root] or {}
    if watched[root][pos.id] then
        watched[root][pos.id] = nil
        if not next(watched[root]) then
            watched[root] = nil
        end
    else
        watched[root][pos.id] = pos
        adapters[root] = adapter
    end
    local on = M.is_watching(root, pos.id)
    vim.notify(
        "lvim-test: " .. (on and "watching " or "unwatched ") .. pos.name,
        vim.log.levels.INFO,
        { title = "lvim-test" }
    )
    ping(root)
    return on
end

--- Stop watching everything under a root (or every root when nil).
---@param root? string
---@return nil
function M.stop(root)
    if root then
        watched[root] = nil
        ping(root)
    else
        local roots = vim.tbl_keys(watched)
        watched = {}
        for _, r in ipairs(roots) do
            ping(r)
        end
    end
end

--- Re-run the watched positions of a root that a save of `path` triggers (scope-filtered), as one
--- transient run.
---@param root string
---@param path string
---@return nil
local function rerun(root, path)
    local set = watched[root]
    local adapter = adapters[root]
    if not set or not adapter then
        return
    end
    local targets, scope_map = {}, {}
    for _, pos in pairs(set) do
        if config.watch.scope == "project" or pos.path == path then
            targets[#targets + 1] = pos
            -- discover the position's file so parse can map its siblings
            local buf = vim.fn.bufnr(pos.path)
            for id, p in pairs(discover.file(adapter, pos.path, buf ~= -1 and buf or nil)) do
                scope_map[id] = p
            end
        end
    end
    if #targets > 0 then
        run.run({ adapter = adapter, root = root, scope_map = scope_map, targets = targets, transient = true })
    end
end

--- Debounced save handler: a write under a watched root schedules a re-run.
---@param path string
---@return nil
local function on_save(path)
    for root, set in pairs(watched) do
        if next(set) and path:sub(1, #root + 1) == root .. "/" then
            local timer = timers[root]
            if timer then
                timer:stop()
            else
                timer = vim.uv.new_timer()
                timers[root] = timer
            end
            timer:start(
                config.watch.debounce_ms or 300,
                0,
                vim.schedule_wrap(function()
                    rerun(root, path)
                end)
            )
        end
    end
end

--- Install the save watcher (once).
---@return nil
function M.setup()
    local group = vim.api.nvim_create_augroup("LvimTestWatch", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(ev)
            local path = vim.api.nvim_buf_get_name(ev.buf)
            if path ~= "" then
                on_save(path)
            end
        end,
    })
end

return M
