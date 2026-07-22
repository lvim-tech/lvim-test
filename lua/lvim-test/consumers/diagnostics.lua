-- lvim-test.consumers.diagnostics: inline failure diagnostics.
-- A pure reader of the results store: on every `User LvimTestResults` it publishes the failed
-- positions' error messages into its OWN `vim.diagnostic` namespace, at the assertion line the
-- adapter extracted (falling back to the test's first line). Signs are OFF here — status signs are
-- the signs consumer's job — leaving virtual text + underline, both config-gated.
--
---@module "lvim-test.consumers.diagnostics"

local config = require("lvim-test.config")
local results = require("lvim-test.results")
local loaded = require("lvim-test.loaded")

local ns = vim.api.nvim_create_namespace("lvim_test_diagnostics")

local M = {}

---@type table<integer, boolean>  buffers we have published diagnostics into (to clear stale ones)
local painted = {}

--- Repaint failure diagnostics for every loaded buffer with a failed position under `root`.
---@param root string
---@return nil
local function repaint(root)
    if not config.diagnostics.enabled then
        return
    end
    local buf_of = loaded.map() -- O(1) path→bufnr (never vim.fn.bufnr per position — see signs.lua)
    ---@type table<string, string>  memo: raw position path → its normalized form
    local norm = {}
    ---@type table<integer, vim.Diagnostic[]>
    local by_buf = {}
    for id, res in pairs(results.for_root(root)) do
        if res.status == "failed" and res.errors then
            local pos = results.position(root, id)
            if pos and pos.range then
                local np = norm[pos.path]
                if not np then
                    np = vim.fs.normalize(pos.path)
                    norm[pos.path] = np
                end
                local buf = buf_of[np]
                if buf then
                    local list = by_buf[buf] or {}
                    for _, err in ipairs(res.errors) do
                        local lnum = (err.line and err.line - 1) or pos.range[1]
                        list[#list + 1] = {
                            lnum = math.max(0, lnum),
                            col = 0,
                            message = err.message or (res.short or "test failed"),
                            severity = config.diagnostics.severity,
                            source = "lvim-test",
                        }
                    end
                    by_buf[buf] = list
                end
            end
        end
    end

    -- Publish into touched buffers; clear buffers that previously had diagnostics but no longer do.
    local now = {}
    for buf, diags in pairs(by_buf) do
        vim.diagnostic.set(ns, buf, diags)
        painted[buf] = true
        now[buf] = true
    end
    for buf in pairs(painted) do
        if not now[buf] and vim.api.nvim_buf_is_loaded(buf) then
            vim.diagnostic.set(ns, buf, {})
            painted[buf] = nil
        end
    end
end

--- Configure the namespace's display + subscribe to the results event.
---@return nil
function M.setup()
    vim.diagnostic.config({
        virtual_text = config.diagnostics.virtual_text and { source = false } or false,
        underline = config.diagnostics.underline,
        signs = false, -- the signs consumer owns the gutter
        severity_sort = true,
    }, ns)

    local group = vim.api.nvim_create_augroup("LvimTestDiagnostics", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "LvimTestResults",
        callback = function(ev)
            if ev.data and ev.data.root then
                repaint(ev.data.root)
            end
        end,
    })
end

return M
