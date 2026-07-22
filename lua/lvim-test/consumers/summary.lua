-- lvim-test.consumers.summary: the test summary sidebar.
-- A PERSISTENT docked tree of the whole project's tests — files → namespaces → tests — built on
-- the shared lvim-ui.tree inside a docked surface (the lvim-lsp outline pattern). Discovery is
-- LAZY: a file node lists its tests only when expanded. Each row shows the position's live status
-- (green passed / red failed / blue skipped / running), a per-file aggregate as dim eol detail,
-- and a mark badge; the whole tree repaints on the single `User LvimTestResults` event. Every
-- action (run / output / mark / …) operates on the row under the cursor via config-bound keys.
--
---@module "lvim-test.consumers.summary"

local config = require("lvim-test.config")
local registry = require("lvim-test.registry")
local discover = require("lvim-test.discover")
local position = require("lvim-test.position")
local results = require("lvim-test.results")
local run = require("lvim-test.run")

local surface = require("lvim-ui.surface")
local tree = require("lvim-ui.tree")
local lvim_ui = require("lvim-ui")
local cursor = require("lvim-utils.cursor")

local FT = "lvim-test-summary"

-- Row descriptions for the help window (key-name → text), in display order.
local HELP = {
    { "run", "run the test / file under the cursor" },
    { "debug", "debug the test (lvim-dap)" },
    { "output", "show the test's output" },
    { "output_short", "show the one-line summary" },
    { "stop", "stop the live run" },
    { "run_failed", "re-run every failed test" },
    { "mark", "toggle a mark on the row" },
    { "run_marked", "run the marked tests" },
    { "clear_marks", "clear all marks" },
    { "watch", "toggle watch (re-run on save)" },
    { "next_failed", "jump to the next failed row" },
    { "prev_failed", "jump to the previous failed row" },
    { "expand_all", "expand every node" },
    { "collapse_all", "collapse every node" },
    { "filter_failed", "toggle failed-only view" },
    { "jump_to", "open the test's source" },
    { "clear", "clear results" },
    { "help", "this help" },
    { "close", "close the panel" },
}

local M = {}

---@type { panel: table?, surface: table?, root: string?, adapter: LvimTestAdapter?, filter_failed: boolean, frame: integer, timer: uv.uv_timer_t?, source_win: integer? }
local state = {
    panel = nil,
    surface = nil,
    root = nil,
    adapter = nil,
    filter_failed = false,
    frame = 1,
    timer = nil,
    source_win = nil,
}

--- Open a position's source file in a normal CODE window — never in the tasks panel, the summary
--- itself, or any float (using `wincmd p` risked editing whatever the previous window was, e.g. the
--- tasks terminal, replacing its content). Prefers the window the summary was opened from, else the
--- first plain editable window, else a fresh split.
---@param pos LvimTestPosition
---@return nil
local function open_source(pos)
    if not pos or not pos.path then
        return
    end
    local mine = state.panel and state.panel.valid() and state.panel.win() or nil
    ---@return boolean
    local function editable(win)
        if not vim.api.nvim_win_is_valid(win) or win == mine then
            return false
        end
        if vim.api.nvim_win_get_config(win).relative ~= "" then
            return false -- a float
        end
        local buf = vim.api.nvim_win_get_buf(win)
        return vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= FT
    end

    local target = (state.source_win and editable(state.source_win)) and state.source_win or nil
    if not target then
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if editable(win) then
                target = win
                break
            end
        end
    end
    if target then
        vim.api.nvim_set_current_win(target)
        vim.cmd.edit(vim.fn.fnameescape(pos.path))
    else
        vim.cmd("topleft split " .. vim.fn.fnameescape(pos.path))
    end
    state.source_win = vim.api.nvim_get_current_win()
    if pos.range then
        pcall(vim.api.nvim_win_set_cursor, 0, { pos.range[1] + 1, pos.range[2] })
    end
end

--- The glyph + highlight for a status string (running uses the current spinner frame).
---@param status string?
---@return string?, string?
local function status_icon(status)
    if status == "passed" then
        return config.icons.passed, "LvimTestPassed"
    elseif status == "failed" then
        return config.icons.failed, "LvimTestFailed"
    elseif status == "skipped" then
        return config.icons.skipped, "LvimTestSkipped"
    elseif status == "running" then
        local f = config.icons.running_frames
        return f[(state.frame - 1) % #f + 1], "LvimTestRunning"
    end
    return nil, nil
end

--- The status icon + highlight for a position (neutral by kind when it has no result yet).
---@param pos LvimTestPosition
---@return string, string
local function status_of(pos)
    local r = state.root and results.get(state.root, pos.id)
    local icon, hl = status_icon(r and r.status)
    if icon then
        return icon, hl or "LvimTestName"
    end
    if pos.kind == "namespace" then
        return config.icons.namespace, "LvimTestNamespace"
    end
    return config.icons.test, "LvimTestName"
end

---@class LvimTestFileAgg
---@field passed integer
---@field failed integer
---@field skipped integer
---@field running integer
---@field status string?

--- Every file's aggregate (path → counts + worst status) computed for the WHOLE store in ONE pass.
--- Called ONCE per rebuild; `file_node` then reads its file's aggregate in O(1). Rebuilding this
--- per file (a full store rescan for each of N files) was O(files × results) and, fired on every
--- streamed result during a suite run, saturated the main loop — the panel "froze". Worst status
--- ranks running > failed > passed > skipped.
---@return table<string, LvimTestFileAgg>
local function file_aggs()
    ---@type table<string, LvimTestFileAgg>
    local aggs = {}
    if not state.root then
        return aggs
    end
    for id, res in pairs(results.for_root(state.root)) do
        local pos = results.position(state.root, id)
        if pos and pos.kind == "test" and pos.path then
            local a = aggs[pos.path]
            if not a then
                a = { passed = 0, failed = 0, skipped = 0, running = 0, status = nil }
                aggs[pos.path] = a
            end
            if a[res.status] ~= nil then
                a[res.status] = a[res.status] + 1
            end
        end
    end
    for _, a in pairs(aggs) do
        a.status = (a.running > 0 and "running")
            or (a.failed > 0 and "failed")
            or (a.passed > 0 and "passed")
            or (a.skipped > 0 and "skipped")
            or nil
    end
    return aggs
end

--- The per-file aggregate as RIGHT-ALIGNED, colour-coded badge cells (e.g. "1 󰅙  13 󰗠": red fail
--- count then green pass count), each `{ text, hl }`, separated by a dim gap cell. Right-aligned so
--- the count survives a narrow panel; per-status colour so the numbers read at a glance. nil when the
--- file has no results yet.
---@param c { passed: integer, failed: integer, skipped: integer, running: integer }
---@return { [1]: string, [2]: string }[]?
local function count_badges(c)
    ---@type { [1]: integer, [2]: string, [3]: string }[]
    local groups = {
        { c.failed, config.icons.failed, "LvimTestFailed" },
        { c.passed, config.icons.passed, "LvimTestPassed" },
        { c.skipped, config.icons.skipped, "LvimTestSkipped" },
    }
    local cells = {}
    for _, g in ipairs(groups) do
        if g[1] > 0 then
            if #cells > 0 then
                cells[#cells + 1] = { "  ", "LvimTestDetail" } -- gap between coloured groups
            end
            cells[#cells + 1] = { g[1] .. " " .. g[2], g[3] }
        end
    end
    return #cells > 0 and cells or nil
end

--- A tree node for a namespace/test position (recursively for a namespace's children).
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return LvimUiTreeNode
local function pos_node(map, pos)
    local icon, ihl = status_of(pos)
    -- A namespace is a bold `{}` HEADER (its icon carries the aggregate status colour, the label the
    -- bold purple hue); a test LEAF wears its status/orange on both icon and label.
    local label_hl = pos.kind == "namespace" and "LvimTestNamespace" or ihl
    local node =
        { id = pos.id, label = pos.name, icon = icon, icon_hl = ihl, label_hl = label_hl, data = { pos = pos } }
    if pos.kind == "namespace" and pos.children and #pos.children > 0 then
        node.expandable = true
        node.children = function()
            local kids = {}
            for _, cid in ipairs(pos.children) do
                if map[cid] then
                    kids[#kids + 1] = pos_node(map, map[cid])
                end
            end
            return kids
        end
    end
    local badges = {}
    if state.root and results.is_marked(state.root, pos.id) then
        badges[#badges + 1] = { config.icons.marked, "LvimTestMarked" }
    end
    if state.root and require("lvim-test.watch").is_watching(state.root, pos.id) then
        badges[#badges + 1] = { config.icons.watching, "LvimTestWatching" }
    end
    if #badges > 0 then
        node.badges = badges
    end
    local r = state.root and results.get(state.root, pos.id)
    if r and r.short then
        node.detail = r.short
    end
    return node
end

--- A lazy file node: expands to its direct namespace/test positions (discovered on demand).
---@param path string
---@param aggs table<string, LvimTestFileAgg>  precomputed per-file aggregates (one store pass)
---@return LvimUiTreeNode
local function file_node(path, aggs)
    local label = path
    if state.root and path:sub(1, #state.root + 1) == state.root .. "/" then
        label = path:sub(#state.root + 2) -- project-relative
    else
        label = vim.fn.fnamemodify(path, ":t")
    end
    -- The file's status rides its LEAD icon (green/red/blue), so the pass/fail state is visible on
    -- the LEFT; the aggregate count rides a RIGHT-ALIGNED badge, so it stays fully visible on a narrow
    -- panel (the tree reserves the badge's width when clipping the path) — never an eol detail that
    -- gets clipped off the right edge.
    local c = aggs[path] or { passed = 0, failed = 0, skipped = 0, running = 0 }
    local sicon, shl = status_icon(c.status)
    local node = {
        id = path,
        label = label,
        -- The ICON carries the aggregate status colour; the LABEL stays the bold teal "header" hue,
        -- so files read as consistent headers with a status dot (the db-drawer look).
        icon = sicon or config.icons.file,
        icon_hl = shl or "LvimTestFile",
        label_hl = "LvimTestFile",
        expandable = true,
        data = { file = path },
        children = function()
            local buf = vim.fn.bufnr(path)
            local map = discover.file(state.adapter, path, buf ~= -1 and buf or nil)
            local kids = {}
            for _, pos in pairs(map) do
                if pos.parent == path then
                    kids[#kids + 1] = pos_node(map, pos)
                end
            end
            table.sort(kids, function(a, b)
                return (a.data.pos.range[1] or 0) < (b.data.pos.range[1] or 0)
            end)
            return kids
        end,
    }
    node.badges = count_badges(c) -- right-aligned, colour-coded per status (nil when no results yet)
    return node
end

--- The top-level nodes: every discovered test file (filtered to files with a failure when
--- `filter_failed`), sorted by path.
---@return LvimUiTreeNode[]
local function build_roots()
    if not state.adapter or not state.root then
        return {}
    end
    local files = discover.walk(state.adapter, state.root)
    table.sort(files)
    local aggs = file_aggs() -- ONE store pass; file_node reads its file's aggregate in O(1)
    local failed_files
    if state.filter_failed then
        failed_files = {}
        for path, a in pairs(aggs) do
            if a.failed > 0 then
                failed_files[path] = true
            end
        end
    end
    local nodes = {}
    for _, path in ipairs(files) do
        if not failed_files or failed_files[path] then
            nodes[#nodes + 1] = file_node(path, aggs)
        end
    end
    return nodes
end

--- Run the position/file under a node.
---@param node LvimUiTreeNode?
---@return nil
local function run_node(node)
    if not node or not node.data then
        return
    end
    local adapter, root = state.adapter, state.root
    ---@cast adapter LvimTestAdapter
    ---@cast root string
    local path = node.data.pos and node.data.pos.path or node.data.file
    if not path then
        return
    end
    local buf = vim.fn.bufnr(path)
    local map = discover.file(adapter, path, buf ~= -1 and buf or nil)
    local target = node.data.pos and (map[node.data.pos.id] or node.data.pos) or map[path]
    if target then
        run.run({ adapter = adapter, root = root, scope_map = map, targets = { target }, keep_focus = true })
    end
end

--- Move the panel cursor to the next/previous FAILED row (rows of the currently-visible tree).
---@param dir "next"|"prev"
---@return nil
local function jump_failed(dir)
    if not (state.panel and state.panel.valid()) then
        return
    end
    local win = state.panel.win()
    ---@cast win integer
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    -- Collect the buffer rows of visible FAILED test nodes.
    local rows = {}
    for _, node in ipairs(state.panel.visible()) do
        local pos = node.data and node.data.pos
        local r = pos and state.root and results.get(state.root, pos.id)
        if r and r.status == "failed" then
            local row = state.panel.row_of(node.id)
            if row then
                rows[#rows + 1] = row
            end
        end
    end
    table.sort(rows)
    local target
    if dir == "next" then
        for _, row in ipairs(rows) do
            if row > cur then
                target = row
                break
            end
        end
    else
        for i = #rows, 1, -1 do
            if rows[i] < cur then
                target = rows[i]
                break
            end
        end
    end
    if target then
        vim.api.nvim_win_set_cursor(win, { target, 0 })
    end
end

--- The help window (canonical lvim-ui.help).
---@return nil
local function show_help()
    local keys = config.summary.keys or {}
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = keys[e[1]]
        if lhs then
            items[#items + 1] = { type(lhs) == "table" and table.concat(lhs, " / ") or lhs, e[2] }
        end
    end
    lvim_ui.help({ title = "Test summary keymaps", items = items, close_keys = { "q", "<Esc>" } })
end

--- Bind the config keymaps on the panel buffer (the tree's on_keys hook).
---@param map fun(lhs: string|string[], fn: fun())
---@return nil
local function set_keys(map)
    local keys = config.summary.keys or {}
    local function sel()
        return state.panel and state.panel.selected() or nil
    end
    local binds = {
        run = function()
            run_node(sel())
        end,
        debug = function()
            local n = sel()
            if n and n.data.pos and state.root and state.adapter then
                local pos = n.data.pos
                local buf = vim.fn.bufnr(pos.path)
                local map = discover.file(state.adapter, pos.path, buf ~= -1 and buf or nil)
                require("lvim-test.dapstrat").run({
                    adapter = state.adapter,
                    root = state.root,
                    scope_map = map,
                    targets = { map[pos.id] or pos },
                    keep_focus = true,
                })
            end
        end,
        output = function()
            local n = sel()
            if n and n.data.pos then
                require("lvim-test.consumers.output").show(state.root, n.data.pos.id, "full")
            end
        end,
        output_short = function()
            local n = sel()
            if n and n.data.pos then
                require("lvim-test.consumers.output").show(state.root, n.data.pos.id, "short")
            end
        end,
        stop = function()
            run.stop(state.root)
        end,
        run_failed = function()
            require("lvim-test").run_failed()
        end,
        mark = function()
            local n = sel()
            if n and n.data.pos and state.root then
                results.toggle_mark(state.root, n.data.pos.id)
            end
        end,
        run_marked = function()
            M.run_marked()
        end,
        watch = function()
            local n = sel()
            if n and n.data.pos and state.root and state.adapter then
                require("lvim-test.watch").toggle(state.root, state.adapter, n.data.pos)
            end
        end,
        clear_marks = function()
            if state.root then
                results.clear_marks(state.root)
            end
        end,
        next_failed = function()
            jump_failed("next")
        end,
        prev_failed = function()
            jump_failed("prev")
        end,
        expand_all = function()
            if state.panel then
                state.panel.expand_all()
            end
        end,
        collapse_all = function()
            if state.panel then
                state.panel.collapse_all()
            end
        end,
        filter_failed = function()
            state.filter_failed = not state.filter_failed
            M.refresh()
        end,
        jump_to = function()
            local n = sel()
            if n and n.data.pos then
                open_source(n.data.pos)
            end
        end,
        clear = function()
            if state.root then
                results.clear(state.root)
            end
        end,
        help = show_help,
        close = function()
            M.close()
        end,
    }
    for name, fn in pairs(binds) do
        local lhs = keys[name]
        if lhs then
            map(lhs, fn)
        end
    end
end

--- Run every marked test under the current root.
---@return nil
function M.run_marked()
    if not (state.adapter and state.root) then
        return
    end
    local ids = results.marked_ids(state.root)
    if #ids == 0 then
        vim.notify("lvim-test: no marked tests", vim.log.levels.INFO, { title = "lvim-test" })
        return
    end
    local targets, scope_map = {}, {}
    for _, id in ipairs(ids) do
        local pos = results.position(state.root, id)
        if pos then
            targets[#targets + 1] = pos
            scope_map[id] = pos
        end
    end
    run.run({ adapter = state.adapter, root = state.root, scope_map = scope_map, targets = targets, keep_focus = true })
end

--- Whether the panel is open.
---@return boolean
function M.is_open()
    return state.panel ~= nil and state.panel.valid()
end

--- Repaint the tree (icons/details/marks) and drive the running spinner.
---@return nil
---@type uv.uv_timer_t?
local refresh_timer

--- Rebuild the tree from the store (cheap — the project walk is cached) and, while anything runs,
--- animate the spinner via a light re-render (no rebuild) on its own timer.
---@return nil
local function rebuild()
    if not M.is_open() then
        return
    end
    ---@cast state -nil
    state.panel.set_root(build_roots())
    local running = state.root and results.counts(state.root).running > 0
    if running and not state.timer then
        state.timer = vim.uv.new_timer()
        local iv = math.floor(1000 / math.max(1, config.status.fps))
        state.timer:start(
            iv,
            iv,
            vim.schedule_wrap(function()
                state.frame = state.frame + 1
                if M.is_open() and state.root and results.counts(state.root).running > 0 then
                    state.panel.refresh() -- light: re-render the running rows' new spinner frame
                else
                    if state.timer then
                        state.timer:stop()
                        state.timer:close()
                        state.timer = nil
                    end
                end
            end)
        )
    end
end

--- Repaint the tree — DEBOUNCED. A streaming run fires a burst of result events; rebuilding on
--- each would block the main loop (freezing the tasks-panel spinner). Coalesce a burst into ONE
--- rebuild ~50ms after it settles.
---@return nil
function M.refresh()
    if not M.is_open() then
        return
    end
    if not refresh_timer then
        refresh_timer = vim.uv.new_timer()
    end
    refresh_timer:stop()
    refresh_timer:start(50, 0, vim.schedule_wrap(rebuild))
end

--- Open the summary sidebar for the current buffer's project.
---@return nil
function M.open()
    if M.is_open() then
        return
    end
    local adapter, root = registry.for_buffer(vim.api.nvim_get_current_buf())
    if not adapter or not root then
        vim.notify(
            "lvim-test: open the summary from a go/dart project buffer",
            vim.log.levels.WARN,
            { title = "lvim-test" }
        )
        return
    end
    state.adapter, state.root = adapter, root
    state.source_win = vim.api.nvim_get_current_win() -- the code window to jump BACK into

    state.panel = tree.new({
        filetype = FT,
        cursorline = true,
        connectors = true,
        empty = " No tests",
        hl = { fold = "LvimTestChevron" }, -- yellow fold arrows
        root = build_roots(),
        on_keys = function(map)
            set_keys(map)
        end,
        on_activate = function(node)
            -- <CR> / l on a test leaf jumps to its source (in a code window, never the tasks panel).
            if node and node.data and node.data.pos then
                open_source(node.data.pos)
            end
        end,
        on_close = function()
            if state.timer then
                state.timer:stop()
                if not state.timer:is_closing() then
                    state.timer:close()
                end
                state.timer = nil
            end
            state.panel, state.surface = nil, nil
        end,
    })

    state.surface = surface.open({
        mode = "split",
        native = true,
        dock = config.summary.side,
        enter = true, -- focus the panel on open (the user drives it straight away)
        persistent = true,
        normal_hl = "NormalSB",
        title = "Tests",
        size = { width = { fixed = config.summary.width } },
        content = { blocks = { { id = "tree", provider = state.panel.provider } } },
        close_keys = {},
        -- Footer legend (DISPLAY-only chips — the keys are already bound on the panel above; a chip's
        -- `run` still fires on click). The surface's place_footer hides this band while a dock (the tasks
        -- panel) overlaps the side tree's bottom, and re-shows it when the dock closes.
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        surface.button({
                            name = "filter",
                            key = config.summary.keys.filter_failed,
                            no_hotkey = true,
                            run = function()
                                state.filter_failed = not state.filter_failed
                                M.refresh()
                            end,
                        }, "action"),
                        surface.button({
                            name = "clear",
                            key = config.summary.keys.clear,
                            no_hotkey = true,
                            run = function()
                                if state.root then
                                    results.clear(state.root)
                                end
                            end,
                        }, "action"),
                        surface.button({
                            name = "help",
                            key = config.summary.keys.help,
                            no_hotkey = true,
                            run = show_help,
                        }, "action"),
                        surface.button({
                            name = "close",
                            key = "q/Esc",
                            no_hotkey = true,
                            run = function()
                                M.close()
                            end,
                        }, "action"),
                    },
                },
            },
        },
    })
end

--- Close the summary sidebar.
---@return nil
function M.close()
    if state.surface and state.surface.close then
        pcall(state.surface.close)
    end
    state.panel, state.surface = nil, nil
end

--- Toggle the summary sidebar.
---@return nil
function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.open()
    end
end

--- Subscribe to the results event (repaint) + self-register the panel filetype for cursor hiding.
---@return nil
function M.setup()
    cursor.register({ panel_ft = { FT } })
    local group = vim.api.nvim_create_augroup("LvimTestSummary", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "LvimTestResults",
        callback = function()
            M.refresh()
        end,
    })
end

return M
