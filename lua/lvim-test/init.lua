-- lvim-test: a native, granular test-runner framework for the lvim-tech ecosystem.
-- The public seam: setup() (load config + adapters + the command + autocmds), the adapter
-- registration API (register), the run verbs, and the statusline segment. The engine composes
-- lvim-tasks (execution), lvim-ui (windows), lvim-utils (theming/persist/cursor) and lvim-ts
-- (treesitter discovery); DAP and lvim-lang are optional. Nothing here is language-specific — the
-- active buffer's adapter (resolved by filetype + root markers) owns all language semantics.
--
-- Discovery is automatic and lazy: the project is walked for candidate test files, and each file's
-- positions are parsed only when opened, run, or expanded in the summary tree.
--
---@module "lvim-test"

local config = require("lvim-test.config")
local registry = require("lvim-test.registry")
local discover = require("lvim-test.discover")
local position = require("lvim-test.position")
local results = require("lvim-test.results")
local run = require("lvim-test.run")

local merge = require("lvim-utils.utils").merge
local hl = require("lvim-utils.highlight")

local TITLE = { title = "lvim-test" }

local M = {}

--- Register (or replace) an adapter — the seam built-ins and external adapters both use. Safe in
--- any load order / at runtime.
---@param adapter LvimTestAdapter
---@return nil
function M.register(adapter)
    registry.register(adapter)
end

--- Resolve the adapter, root, discovered scope map and cursor position for the current buffer.
--- Returns nil (with a notice) when no adapter claims the buffer / it is not a test file.
---@param need_test_file boolean  require the buffer to BE a test file (nearest/file), not just in a project
---@return LvimTestAdapter?, string?, table<string, LvimTestPosition>?, integer?
local function resolve_buffer(need_test_file)
    local bufnr = vim.api.nvim_get_current_buf()
    local adapter, root = registry.for_buffer(bufnr)
    if not adapter or not root then
        vim.notify("lvim-test: no test adapter for this buffer", vim.log.levels.WARN, TITLE)
        return nil
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if need_test_file and not adapter.is_test_file(path, root) then
        vim.notify("lvim-test: not a test file", vim.log.levels.WARN, TITLE)
        return nil
    end
    local map = adapter.is_test_file(path, root) and discover.file(adapter, path, bufnr) or {}
    return adapter, root, map, bufnr
end

--- The runner args after a `--` token (`:LvimTest run -- -race -count=1`), else nil.
---@param args? string[]
---@return string[]?
local function extra_args(args)
    if not args then
        return nil
    end
    for i, a in ipairs(args) do
        if a == "--" then
            local rest = { unpack(args, i + 1) }
            return #rest > 0 and rest or nil
        end
    end
    return nil
end

--- Run the nearest test (the innermost test/namespace at the cursor, else the whole file).
---@param args? string[]
---@return nil
function M.run_nearest(args)
    local adapter, root, map, bufnr = resolve_buffer(true)
    if not adapter or not root or not map or not bufnr then
        return
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    local cur = vim.api.nvim_win_get_cursor(0)
    local pos = position.nearest(map, path, cur[1] - 1, cur[2]) or map[path]
    if not pos then
        vim.notify("lvim-test: no test found in this file", vim.log.levels.WARN, TITLE)
        return
    end
    run.run({ adapter = adapter, root = root, scope_map = map, targets = { pos }, extra_args = extra_args(args) })
end

--- Run every test in the current file.
---@param args? string[]
---@return nil
function M.run_file(args)
    local adapter, root, map, bufnr = resolve_buffer(true)
    if not adapter or not root or not map or not bufnr then
        return
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    local file_pos = map[path]
    if not file_pos then
        vim.notify("lvim-test: no tests in this file", vim.log.levels.WARN, TITLE)
        return
    end
    run.run({ adapter = adapter, root = root, scope_map = map, targets = { file_pos }, extra_args = extra_args(args) })
end

--- Run the whole project suite (every discovered test under the root).
---@return nil
function M.run_suite()
    local adapter, root = registry.for_buffer(vim.api.nvim_get_current_buf())
    if not adapter or not root then
        vim.notify("lvim-test: no test adapter for this buffer", vim.log.levels.WARN, TITLE)
        return
    end
    -- Run the WHOLE project WITHOUT pre-parsing every test file — parsing hundreds of files up
    -- front froze Neovim on a big repo. A synthetic "dir" target makes the adapter emit its
    -- whole-project command (`go test ./...` / `flutter test`); per-test results map to positions
    -- discovered LAZILY as the run streams them (the adapter resolves each result's own file).
    local suite = { id = root, kind = "dir", name = "suite", path = root, children = {} }
    run.run({ adapter = adapter, root = root, scope_map = { [root] = suite }, targets = { suite } })
end

--- Replay the last run in the current project.
---@return nil
function M.run_last()
    local _, root = registry.for_buffer(vim.api.nvim_get_current_buf())
    if not root then
        vim.notify("lvim-test: no test adapter for this buffer", vim.log.levels.WARN, TITLE)
        return
    end
    run.run_last(root)
end

--- Re-run every currently-failed test in the current project.
---@return nil
function M.run_failed()
    local adapter, root = registry.for_buffer(vim.api.nvim_get_current_buf())
    if not adapter or not root then
        vim.notify("lvim-test: no test adapter for this buffer", vim.log.levels.WARN, TITLE)
        return
    end
    local targets, scope_map = {}, {}
    for _, id in ipairs(results.failed_ids(root)) do
        local pos = results.position(root, id)
        if pos then
            targets[#targets + 1] = pos
            scope_map[id] = pos
        end
    end
    if #targets == 0 then
        vim.notify("lvim-test: no failed tests to re-run", vim.log.levels.INFO, TITLE)
        return
    end
    run.run({ adapter = adapter, root = root, scope_map = scope_map, targets = targets })
end

--- Debug the nearest test through lvim-dap.
---@return nil
function M.debug()
    local adapter, root, map, bufnr = resolve_buffer(true)
    if not adapter or not root or not map or not bufnr then
        return
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    local cur = vim.api.nvim_win_get_cursor(0)
    local pos = position.nearest(map, path, cur[1] - 1, cur[2]) or map[path]
    if not pos then
        vim.notify("lvim-test: no test found here", vim.log.levels.WARN, TITLE)
        return
    end
    require("lvim-test.dapstrat").run({ adapter = adapter, root = root, scope_map = map, targets = { pos } })
end

--- Show the nearest test's output (`short` = the one-line summary, else the full captured output).
---@param args string[]
---@return nil
function M.output(args)
    require("lvim-test.consumers.output").show_nearest(args[1] == "short" and "short" or "full")
end

--- Jump to the next/previous test (`:LvimTest jump next|prev [failed]`).
---@param args string[]
---@return nil
function M.jump(args)
    local dir = vim.tbl_contains(args, "prev") and "prev" or "next"
    local failed = vim.tbl_contains(args, "failed")
    require("lvim-test.consumers.jump").jump(dir, failed)
end

--- Toggle the summary sidebar.
---@return nil
function M.summary()
    require("lvim-test.consumers.summary").toggle()
end

--- Toggle watching the nearest test (re-run on save); `stop` stops every watch.
---@param args string[]
---@return nil
function M.watch(args)
    if args[1] == "stop" then
        require("lvim-test.watch").stop()
        vim.notify("lvim-test: watching stopped", vim.log.levels.INFO, TITLE)
        return
    end
    local adapter, root, map, bufnr = resolve_buffer(true)
    if not adapter or not root or not map or not bufnr then
        return
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    local cur = vim.api.nvim_win_get_cursor(0)
    local pos = position.nearest(map, path, cur[1] - 1, cur[2]) or map[path]
    if pos then
        require("lvim-test.watch").toggle(root, adapter, pos)
    end
end

--- Clear all results / diagnostics / signs for the current project.
---@return nil
function M.clear()
    local _, root = registry.for_buffer(vim.api.nvim_get_current_buf())
    results.clear(root)
end

--- Stop the live run.
---@return nil
function M.stop()
    local _, root = registry.for_buffer(vim.api.nvim_get_current_buf())
    run.stop(root)
end

--- Focus the live run's terminal output.
---@return nil
function M.attach()
    local _, root = registry.for_buffer(vim.api.nvim_get_current_buf())
    run.attach(root)
end

--- Drop discovery caches and re-parse open test buffers.
---@return nil
function M.refresh()
    discover.invalidate()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local adapter, root = registry.for_buffer(bufnr)
            local path = vim.api.nvim_buf_get_name(bufnr)
            if adapter and root and path ~= "" and adapter.is_test_file(path, root) then
                discover.file(adapter, path, bufnr)
            end
        end
    end
    vim.notify("lvim-test: discovery refreshed", vim.log.levels.INFO, TITLE)
end

--- Statusline segment for the current buffer's project root (aggregate pass/fail/skip), formatted
--- per `config.status.format`. Empty string when the buffer has no adapter / no results.
---@param bufnr? integer
---@return string
function M.status(bufnr)
    local _, root = registry.for_buffer(bufnr or vim.api.nvim_get_current_buf())
    if not root then
        return ""
    end
    local c = results.counts(root)
    if c.passed + c.failed + c.skipped + c.running == 0 then
        return ""
    end
    local out = config.status.format
    out = out:gsub("{passed}", config.icons.passed .. " " .. c.passed)
    out = out:gsub("{failed}", config.icons.failed .. " " .. c.failed)
    out = out:gsub("{skipped}", config.icons.skipped .. " " .. c.skipped)
    return out
end

---@type table<string, fun(args: string[])>
local subs = {
    run = M.run_nearest,
    file = M.run_file,
    suite = M.run_suite,
    last = M.run_last,
    failed = M.run_failed,
    debug = M.debug,
    output = M.output,
    jump = M.jump,
    summary = M.summary,
    watch = M.watch,
    clear = M.clear,
    stop = M.stop,
    attach = M.attach,
    refresh = M.refresh,
}

-- Argument completion per subcommand (the 2nd token onward).
---@type table<string, string[]>
local sub_args = {
    jump = { "next", "prev", "failed" },
    output = { "short" },
    watch = { "stop" },
}

--- The :LvimTest dispatcher.
---@param fargs string[]
---@return nil
local function dispatch(fargs)
    local sub = fargs[1]
    if not sub or sub == "" then
        return M.run_nearest()
    end
    local fn = subs[sub]
    if not fn then
        vim.notify("lvim-test: unknown command '" .. sub .. "'", vim.log.levels.WARN, TITLE)
        return
    end
    fn({ unpack(fargs, 2) })
end

--- Configure lvim-test: merge user options into the live config, load the enabled built-in
--- adapters (each self-registers), install the :LvimTest command, and wire discovery-cache
--- invalidation on save.
---@param opts? table
---@return nil
function M.setup(opts)
    merge(config, opts or {})

    -- Self-theming groups (re-derived on ColorScheme / palette sync).
    hl.bind(require("lvim-test.highlights").build)

    -- Load built-in adapters (each require self-registers into the registry).
    for _, name in ipairs(config.adapters.enabled or {}) do
        pcall(require, "lvim-test.adapters." .. name)
    end

    -- Result consumers: gutter signs + spinner and inline failure diagnostics. Each subscribes to
    -- the single `User LvimTestResults` event and repaints itself — no direct wiring from the run.
    require("lvim-test.consumers.signs").setup()
    require("lvim-test.consumers.diagnostics").setup()
    require("lvim-test.consumers.summary").setup()
    require("lvim-test.watch").setup()

    -- Invalidate a file's discovery cache when it is written (its positions may have moved).
    local group = vim.api.nvim_create_augroup("LvimTest", { clear = true })
    vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
        group = group,
        callback = function(ev)
            discover.invalidate(vim.api.nvim_buf_get_name(ev.buf))
        end,
    })

    vim.api.nvim_create_user_command("LvimTest", function(cmd)
        dispatch(cmd.fargs)
    end, {
        nargs = "*",
        complete = function(arg, line)
            local words = vim.split(vim.trim(line), "%s+")
            -- Completing an ARGUMENT to a subcommand (a 3rd+ token, or a trailing space after the sub).
            local pool = vim.tbl_keys(subs)
            if #words > 2 or (#words == 2 and arg == "") then
                pool = sub_args[words[2]] or {}
            end
            table.sort(pool)
            return vim.tbl_filter(function(s)
                return arg == "" or s:find(arg, 1, true) == 1
            end, pool)
        end,
        desc = "lvim-test: run / file / suite / last / failed / output / jump / stop / attach / clear / refresh",
    })
end

return M
