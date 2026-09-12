-- lvim-test.consumers.signs: gutter status signs + eol status on each test line.
-- A pure reader of the results store: on every `User LvimTestResults` it repaints the signs for
-- the affected root — a coloured dot in the sign column on each test's first line (green passed,
-- red failed, blue skipped, yellow running) and, optionally, an eol status icon + short message.
-- Running tests animate a shared braille spinner driven by ONE timer that only ticks while
-- something is running, so an idle editor costs nothing.
--
-- Signs are extmarks (`sign_text` / `sign_hl_group`), the lvim-dap breakpoints model — no legacy
-- `sign_define`, so they move with edits and clear per buffer on repaint.
--
---@module "lvim-test.consumers.signs"

local config = require("lvim-test.config")
local results = require("lvim-test.results")
local loaded = require("lvim-test.loaded")

local ns = vim.api.nvim_create_namespace("lvim_test_signs")

local M = {}

---@type uv.uv_timer_t?
local timer
---@type integer
local frame = 1
---@type table<string, boolean>  roots with at least one running position (drive the spinner)
local spinning = {}

---@type table<string, table<integer, boolean>>  root → buffers this consumer painted signs into
--- A repaint only touches buffers that still hold a result; without this record a buffer whose
--- results were CLEARED (`:LvimTest clear`, a re-run that dropped a file) kept its old dots forever,
--- because nothing ever visited it again to wipe the namespace.
local painted = {}

--- The sign glyph + highlight for a status (running uses the current spinner frame).
---@param status string
---@return string, string
local function sign_for(status)
    if status == "passed" then
        return config.icons.passed, "LvimTestPassedSign"
    elseif status == "failed" then
        return config.icons.failed, "LvimTestFailedSign"
    elseif status == "skipped" then
        return config.icons.skipped, "LvimTestSkippedSign"
    elseif status == "running" then
        local frames = config.icons.running_frames
        return frames[(frame - 1) % #frames + 1], "LvimTestRunningSign"
    end
    return "", "LvimTestSkippedSign"
end

--- The fg highlight for a status (eol status text).
---@param status string
---@return string
local function status_hl(status)
    return status == "passed" and "LvimTestPassed"
        or status == "failed" and "LvimTestFailed"
        or status == "skipped" and "LvimTestSkipped"
        or "LvimTestRunning"
end

--- Repaint every loaded buffer that holds a test position with a result under `root`. Clears the
--- namespace per touched buffer first, so cleared/removed results disappear.
---@param root string
---@return nil
local function repaint(root)
    if not config.status.signs and not config.status.virtual_text then
        return
    end
    -- Group results by their owning buffer (only loaded buffers get signs). The path→bufnr lookup is
    -- an O(1) hit in a map built ONCE from the loaded buffers — never `vim.fn.bufnr` per position (its
    -- per-call buffer-list scan, ×N results ×spinner-fps, was what froze the main loop).
    local buf_of = loaded.map()
    ---@type table<string, string>  memo: raw position path → its normalized form
    local norm = {}
    ---@type table<integer, { row: integer, status: string, short?: string }[]>
    local by_buf = {}
    local running = false
    for id, res in pairs(results.for_root(root)) do
        local pos = results.position(root, id)
        if pos and pos.kind == "test" and pos.range then
            local np = norm[pos.path]
            if not np then
                np = vim.fs.normalize(pos.path)
                norm[pos.path] = np
            end
            local buf = buf_of[np]
            if buf then
                local list = by_buf[buf] or {}
                list[#list + 1] = { row = pos.range[1], status = res.status, short = res.short }
                by_buf[buf] = list
            end
            if res.status == "running" then
                running = true
            end
        end
    end

    -- Buffers painted on a previous pass that hold no result now: wipe their dots. A `clear()` of every
    -- root arrives with root == "" — sweep every recorded buffer then.
    local now = {}
    local roots = (root == "") and vim.tbl_keys(painted) or { root }
    for _, r in ipairs(roots) do
        for buf in pairs(painted[r] or {}) do
            if not by_buf[buf] and vim.api.nvim_buf_is_loaded(buf) then
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            end
        end
        painted[r] = nil
    end

    for buf, list in pairs(by_buf) do
        now[buf] = true
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        local lines = vim.api.nvim_buf_line_count(buf)
        for _, it in ipairs(list) do
            if it.row < lines then
                local opts = {}
                if config.status.signs then
                    local glyph, shl = sign_for(it.status)
                    opts.sign_text = glyph
                    opts.sign_hl_group = shl
                end
                if config.status.virtual_text then
                    local glyph = sign_for(it.status)
                    local txt = glyph .. (it.short and (" " .. it.short) or "")
                    opts.virt_text = { { txt, status_hl(it.status) } }
                    opts.virt_text_pos = "eol"
                end
                pcall(vim.api.nvim_buf_set_extmark, buf, ns, it.row, 0, opts)
            end
        end
    end
    if next(now) then
        painted[root] = now
    end

    spinning[root] = running or nil
    M.tick_timer()
end

--- Ensure the spinner timer runs iff some root has a running position; on each tick advance the
--- frame and repaint the spinning roots.
---@return nil
function M.tick_timer()
    local any = next(spinning) ~= nil
    if any and not timer then
        local t = vim.uv.new_timer()
        if not t then
            return
        end
        timer = t
        local interval = math.floor(1000 / math.max(1, config.status.fps))
        t:start(
            interval,
            interval,
            vim.schedule_wrap(function()
                frame = frame + 1
                for root in pairs(spinning) do
                    repaint(root)
                end
            end)
        )
    elseif not any and timer then
        timer:stop()
        timer:close()
        timer = nil
    end
end

--- Repaint the root that owns a buffer (used when a test file becomes visible after a run).
---@param bufnr integer
---@return nil
function M.repaint_buffer(bufnr)
    local _, root = require("lvim-test.registry").for_buffer(bufnr)
    if root then
        repaint(root)
    end
end

--- Subscribe to the results event + buffer visibility.
---@return nil
function M.setup()
    local group = vim.api.nvim_create_augroup("LvimTestSigns", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "LvimTestResults",
        callback = function(ev)
            if ev.data and ev.data.root then
                repaint(ev.data.root)
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "BufWinEnter", "BufReadPost" }, {
        group = group,
        callback = function(ev)
            M.repaint_buffer(ev.buf)
        end,
    })
end

return M
