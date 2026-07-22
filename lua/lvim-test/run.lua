-- lvim-test.run: the run pipeline.
-- Turns a run REQUEST (which positions to run, under one adapter+root) into a running test process
-- through lvim-tasks, taps its output line-by-line for streaming results, and parses the final
-- output into per-position statuses — all landing in the results store. The engine owns run
-- bookkeeping (the one live task per root, stop/attach) but knows nothing language-specific: the
-- adapter builds the argv and parses the output.
--
-- Output handling: lvim-tasks streams a task's stdout to `hooks.on_output` as raw jobstart chunks
-- (data[1] continues the previous partial line; the last element is a partial). We reassemble
-- complete lines, strip the pty's trailing CR, accumulate them for the final parse, and feed each
-- to the adapter's optional `stream` for live results. The full terminal buffer remains the human
-- output surface (attach / panel).
--
---@module "lvim-test.run"

local config = require("lvim-test.config")
local position = require("lvim-test.position")
local results = require("lvim-test.results")
local project = require("lvim-test.project")

local M = {}

---@class LvimTestRunRequest
---@field adapter    LvimTestAdapter
---@field root       string
---@field scope_map  table<string, LvimTestPosition>  every position in the run's scope (for lookup)
---@field targets    LvimTestPosition[]                the positions to run (their subtrees)
---@field positions? LvimTestPosition[]                alias of `targets` for adapters (set by run())
---@field extra_args? string[]
---@field env?       table<string,string>
---@field transient?  boolean                          a throwaway run (watch re-run) — see lvim-tasks
---@field keep_focus? boolean                          reveal the tasks panel but KEEP focus where it is (tree runs)

---@class LvimTestSpec
---@field cmd      string[]              argv (list form always)
---@field cwd?     string
---@field env?     table<string,string>
---@field matcher? string                lvim-tasks problem-matcher (quickfix, a bonus)
---@field context? table                 adapter state carried into stream/parse

---@type table<string, LvimTask>  root → the live test task
local live = {}

---@type table<string, LvimTestRunRequest>  root → the last request (for `:LvimTest last`)
local last_req = {}

--- Persist-before-run per `config.run.save`.
---@return nil
local function do_save()
    local mode = config.run.save
    if mode == "all" then
        pcall(vim.cmd, "silent! wall")
    elseif mode == "current" then
        if vim.bo.modifiable and vim.bo.modified and vim.api.nvim_buf_get_name(0) ~= "" then
            pcall(vim.cmd, "silent! write")
        end
    end
end

--- The TEST-leaf ids a run covers: the `test` positions in the subtree of every target. Container
--- positions (dir/file/namespace) are NOT included — they carry no run status of their own; their
--- state is an aggregate of these leaves (the summary tree derives it). This keeps a whole-file run
--- from stamping the file node itself as "skipped".
---@param scope_map table<string, LvimTestPosition>
---@param targets LvimTestPosition[]
---@return string[]
local function covered_ids(scope_map, targets)
    local seen, ids = {}, {}
    for _, t in ipairs(targets) do
        for _, id in ipairs(position.subtree(scope_map, t.id)) do
            local pos = scope_map[id]
            if pos and pos.kind == "test" and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    return ids
end

--- Run a request. Marks the covered positions running, launches the adapter's spec through
--- lvim-tasks, streams + parses results back into the store. Returns the LvimTask, or nil when the
--- adapter could not build a spec / a run is already busy (per config.run.on_busy).
---@param req LvimTestRunRequest
---@return LvimTask?
function M.run(req)
    local adapter, root = req.adapter, req.root
    if not adapter or not root then
        return nil
    end

    -- One live run per root unless concurrency is enabled; honour on_busy.
    local busy = live[root]
    if busy and busy:is_running() and not config.run.concurrent then
        if config.run.on_busy == "reject" then
            vim.notify("lvim-test: a run is already in progress", vim.log.levels.WARN, { title = "lvim-test" })
            return nil
        elseif config.run.on_busy == "replace" then
            require("lvim-tasks").stop(busy.id)
        end
        -- "queue" falls through — lvim-tasks serialises by starting the new task; the old one keeps
        -- its buffer. (True queueing is a later refinement; replace/reject cover the common cases.)
    end

    do_save()

    project.apply(req) -- fold <root>/.lvim/test/config.lua overrides into the request
    req.positions = req.targets
    local spec = adapter.build(req)
    if not spec or type(spec.cmd) ~= "table" or #spec.cmd == 0 then
        vim.notify(
            "lvim-test: " .. adapter.name .. " built no command here",
            vim.log.levels.WARN,
            { title = "lvim-test" }
        )
        return nil
    end

    local ids = covered_ids(req.scope_map, req.targets)
    results.set_positions(root, req.scope_map)
    results.set_running(root, ids)

    -- The context threaded into stream/parse: accumulated complete output lines, the scope map for
    -- name→id lookup, the adapter's own carried state, and (at exit) the exit code.
    local ctx = {
        root = root,
        adapter = adapter,
        req = req,
        scope_map = req.scope_map,
        targets = req.targets,
        covered = ids,
        lines = {},
        context = spec.context,
        exit_code = nil,
        finalized = false, -- guards finalize() (natural exit OR protocol `done`) to run once
        protocol_done = false, -- an adapter's stream sets this on an authoritative completion event
        protocol_ok = true, -- the completion's success flag (from the protocol's `done`)
        task = nil, -- THIS run's LvimTask (set after launch) — for per-run protocol-done completion
    }

    -- Resolve the run to final statuses ONCE: parse the accumulated output, resolve covered positions
    -- the parse never mentioned (a crash / filtered-out run → config.run.missing_result), and let the
    -- output consumer honour open_on_fail. Runs from BOTH the natural process exit and an adapter's
    -- protocol-completion signal (see feed), guarded so it runs exactly once.
    local function finalize()
        if ctx.finalized then
            return
        end
        ctx.finalized = true
        local final = {}
        local ok, parsed = pcall(adapter.parse, ctx)
        if ok and type(parsed) == "table" then
            final = parsed
        end
        for _, id in ipairs(ids) do
            if final[id] == nil then
                local cur = results.get(root, id)
                if cur and cur.status == "running" then
                    final[id] = { status = config.run.missing_result }
                end
            end
        end
        results.merge(root, final)
        for _, id in ipairs(ids) do
            local r = results.get(root, id)
            if r and r.status == "failed" then
                pcall(function()
                    require("lvim-test.consumers.output").on_run_failed(root)
                end)
                break
            end
        end
    end

    local partial = ""
    local function feed(line)
        line = line:gsub("\r$", "") -- strip the pty CR
        ctx.lines[#ctx.lines + 1] = line
        if adapter.stream then
            local ok, partials = pcall(adapter.stream, line, ctx)
            if ok and type(partials) == "table" and next(partials) then
                results.merge(root, partials)
            end
        end
        -- The adapter can signal PROTOCOL completion (dart's `{"type":"done"}`) — authoritative even
        -- when the OS process lingers: `flutter test` emits `done`, then its flutter_tester children
        -- outlive it, holding the pty open so the job's own exit never fires and the task would hang
        -- "running" forever. On that signal, finalize now and reap the process group via complete().
        if ctx.protocol_done and not ctx.finalized then
            finalize()
            -- Complete THIS run's OWN task (ctx.task), NOT live[root]: with concurrent runs (several
            -- tests launched from the summary before the first finishes) live[root] holds only the
            -- LATEST task, so completing it would leave every earlier run hung "running" forever.
            if ctx.task then
                require("lvim-tasks").complete(ctx.task.id, ctx.protocol_ok ~= false)
            end
        end
    end

    local task = require("lvim-tasks").run({
        name = "test: " .. adapter.name .. " " .. (req.targets[1] and req.targets[1].name or root),
        cmd = spec.cmd,
        cwd = spec.cwd or root,
        env = spec.env,
        matcher = spec.matcher,
        group = "Test",
        transient = req.transient == true, -- a watch re-run stays out of the durable task history
        hooks = {
            on_output = function(_, data)
                partial = partial .. (data[1] or "")
                for i = 2, #data do
                    feed(partial)
                    partial = data[i]
                end
            end,
            on_exit = function(task_)
                if partial ~= "" then
                    feed(partial)
                    partial = ""
                end
                ctx.exit_code = task_.exit_code
                finalize() -- no-op if a protocol `done` already finalized this run
            end,
        },
    })

    if task then
        ctx.task = task -- THIS run's task, so feed()'s protocol-done completion targets the right one
        live[root] = task
        last_req[root] = req
        -- Reveal the tasks panel (the live test output) so a run is visible — but NOT for a
        -- transient watch re-run (it would keep popping the panel on every save). A run from the
        -- summary tree still OPENS the panel (you want the output) but keeps focus in the tree
        -- (`keep_focus`) — the panel opening must not yank the cursor out of the sidebar.
        if config.run.open_panel and not req.transient then
            local keep = req.keep_focus and vim.api.nvim_get_current_win() or nil
            pcall(function()
                require("lvim-tasks").open()
            end)
            if keep then
                -- The dock enters the tasks panel on a DEFERRED tick, so a plain schedule restores
                -- focus too early (the dock then re-steals it). Restore a beat later, after it settles.
                vim.defer_fn(function()
                    if vim.api.nvim_win_is_valid(keep) then
                        pcall(vim.api.nvim_set_current_win, keep)
                    end
                end, 60)
            end
        end
    end
    return task
end

--- Replay the last run for a root (the `:LvimTest last` verb). Returns nil when nothing has run.
---@param root string
---@return LvimTask?
function M.run_last(root)
    local req = last_req[root]
    if not req then
        vim.notify("lvim-test: nothing has run yet in this project", vim.log.levels.INFO, { title = "lvim-test" })
        return nil
    end
    return M.run(req)
end

--- Stop the live test run for a root (default: the current buffer's root, else any live run).
---@param root? string
---@return boolean
function M.stop(root)
    local task = root and live[root]
    if not task then
        for _, t in pairs(live) do
            if t:is_running() then
                task = t
                break
            end
        end
    end
    if not task then
        vim.notify("lvim-test: nothing is running", vim.log.levels.WARN, { title = "lvim-test" })
        return false
    end
    return require("lvim-tasks").stop(task.id)
end

--- Focus the live run's terminal (the full output) via the lvim-tasks panel.
---@param root? string
---@return nil
function M.attach(root)
    local task = root and live[root]
    if not task then
        for _, t in pairs(live) do
            task = t
            break
        end
    end
    if not task then
        vim.notify("lvim-test: no run to attach to", vim.log.levels.WARN, { title = "lvim-test" })
        return
    end
    require("lvim-tasks").open()
end

--- The live task for a root, if any (for consumers / status).
---@param root string
---@return LvimTask?
function M.live_task(root)
    return live[root]
end

return M
