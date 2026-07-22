-- lvim-test.results: the results store + the single observation seam.
-- ONE in-memory table of per-position results per project root, plus per-root aggregate counters.
-- Consumers (signs, diagnostics, statusline, the summary tree) are PURE READERS: they never get
-- called back directly — every mutation fires ONE `User LvimTestResults` autocmd (payload
-- { root, ids }), exactly the `LvimTasksChanged` pattern, so there are no callback webs and any
-- number of consumers can observe the same store independently.
--
-- (Persistence — last run / marks / last statuses via lvim-utils.store — is layered on in a later
-- milestone; this module owns only the live store + the event.)
--
---@module "lvim-test.results"

local M = {}

---@type table<string, table<string, LvimTestResult>>  root → (position id → result)
local store = {}

---@type table<string, table<string, LvimTestPosition>>  root → (position id → position)
local positions = {}

---@type table<string, { passed: integer, failed: integer, skipped: integer, running: integer }>
local counts = {}

--- Record the position objects a run's ids refer to, so consumers (signs, diagnostics, the tree)
--- can resolve an id back to its file + range without re-discovering. Called by the run pipeline
--- with the run's scope map before results arrive.
---@param root string
---@param map table<string, LvimTestPosition>
---@return nil
function M.set_positions(root, map)
    positions[root] = positions[root] or {}
    for id, pos in pairs(map) do
        positions[root][id] = pos
    end
end

--- The position an id refers to under a root, if known.
---@param root string
---@param id string
---@return LvimTestPosition?
function M.position(root, id)
    return (positions[root] or {})[id]
end

--- Recompute a root's aggregate counters from its result table.
---@param root string
---@return nil
local function recount(root)
    local c = { passed = 0, failed = 0, skipped = 0, running = 0 }
    for _, res in pairs(store[root] or {}) do
        if c[res.status] ~= nil then
            c[res.status] = c[res.status] + 1
        end
    end
    counts[root] = c
end

---@type uv.uv_timer_t?
local emit_timer
---@type table<string, table<string, boolean>>  root → changed ids pending an emit
local pending = {}

--- Flush the coalesced changed-id sets: ONE `User LvimTestResults` per touched root.
---@return nil
local function flush()
    local snapshot = pending
    pending = {}
    for root, ids in pairs(snapshot) do
        local flat = {}
        for id in pairs(ids) do
            flat[#flat + 1] = id
        end
        vim.api.nvim_exec_autocmds("User", { pattern = "LvimTestResults", data = { root = root, ids = flat } })
    end
end

--- Fire the observation event — COALESCED. A streaming suite run merges results per test; firing
--- (and repainting every consumer) on EACH would hammer the main loop — frozen spinners, dead
--- navigation, an apparent hang. Accumulate the changed ids and emit ~50ms after the burst settles.
---@param root string
---@param ids string[]
---@return nil
local function emit(root, ids)
    local set = pending[root]
    if not set then
        set = {}
        pending[root] = set
    end
    for _, id in ipairs(ids) do
        set[id] = true
    end
    if not emit_timer then
        emit_timer = vim.uv.new_timer()
    end
    emit_timer:stop()
    emit_timer:start(50, 0, vim.schedule_wrap(flush))
end

--- Mark a set of position ids "running" (clearing any prior result) and notify. Used the moment a
--- run starts, so the spinner/tree show progress before any output arrives.
---@param root string
---@param ids string[]
---@return nil
function M.set_running(root, ids)
    store[root] = store[root] or {}
    for _, id in ipairs(ids) do
        store[root][id] = { status = "running" }
    end
    recount(root)
    emit(root, ids)
end

--- Merge a batch of results into a root (partial, from streaming, or full from a final parse) and
--- notify with exactly the ids that changed.
---@param root string
---@param results table<string, LvimTestResult>
---@return nil
function M.merge(root, results)
    store[root] = store[root] or {}
    local ids = {}
    for id, res in pairs(results) do
        store[root][id] = res
        ids[#ids + 1] = id
    end
    recount(root)
    emit(root, ids)
end

--- The result for one position id under a root, if any.
---@param root string
---@param id string
---@return LvimTestResult?
function M.get(root, id)
    return (store[root] or {})[id]
end

--- The whole result table for a root (read-only view; do not mutate).
---@param root string
---@return table<string, LvimTestResult>
function M.for_root(root)
    return store[root] or {}
end

--- The aggregate counters for a root.
---@param root string
---@return { passed: integer, failed: integer, skipped: integer, running: integer }
function M.counts(root)
    return counts[root] or { passed = 0, failed = 0, skipped = 0, running = 0 }
end

--- Every id currently failed under a root (for run-failed / jump).
---@param root string
---@return string[]
function M.failed_ids(root)
    local ids = {}
    for id, res in pairs(store[root] or {}) do
        if res.status == "failed" then
            ids[#ids + 1] = id
        end
    end
    return ids
end

---@type table<string, table<string, boolean>>  root → set of marked position ids
local marks = {}

--- Toggle a position's mark under a root; returns the new marked state.
---@param root string
---@param id string
---@return boolean marked
function M.toggle_mark(root, id)
    marks[root] = marks[root] or {}
    marks[root][id] = not marks[root][id] or nil
    emit(root, { id })
    return marks[root][id] == true
end

--- Whether a position id is marked.
---@param root string
---@param id string
---@return boolean
function M.is_marked(root, id)
    return (marks[root] or {})[id] == true
end

--- Every marked id under a root.
---@param root string
---@return string[]
function M.marked_ids(root)
    local ids = {}
    for id in pairs(marks[root] or {}) do
        ids[#ids + 1] = id
    end
    return ids
end

--- Clear all marks under a root and notify.
---@param root string
---@return nil
function M.clear_marks(root)
    marks[root] = nil
    emit(root, {})
end

--- Clear all results for a root (or everything when root is nil) and notify.
---@param root? string
---@return nil
function M.clear(root)
    if root then
        store[root] = nil
        counts[root] = nil
        positions[root] = nil
        marks[root] = nil
        emit(root, {})
    else
        store, counts, positions, marks = {}, {}, {}, {}
        emit("", {})
    end
end

return M
