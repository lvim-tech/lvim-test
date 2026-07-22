-- lvim-test.registry: the adapter registry.
-- One place every language adapter registers into — built-ins loaded by setup() from
-- config.adapters.enabled, external adapters via require("lvim-test").register(adapter) in ANY
-- load order. Mirrors the lvim-lang provider registry / lvim-utils.cursor.register pattern:
-- registration EXTENDS a live index (a filetype → adapters map) so `for_buffer` resolves the
-- owning adapter + project root of a buffer without the engine ever branching on a language.
--
-- An adapter is (mostly) data + four functions — see the LvimTestAdapter contract below. The
-- engine calls those; it never knows what "go" or "pytest" means.
--
---@module "lvim-test.registry"

---@class LvimTestAdapter
---@field name          string    Unique id ("go", "pytest", "jest", "cargo")
---@field filetypes     string[]  Buffers that can belong to this adapter
---@field root_markers  string[]  Walked up from the file (vim.fs.root) to find the project root
---@field is_test_file  fun(path: string, root: string): boolean  NAME test only — must be cheap
---@field lang?         string    Treesitter language (default: the buffer's filetype)
---@field query?        string|fun(root: string): string  Discovery query (captures, see discover)
---@field discover?     fun(ctx: LvimTestDiscoverCtx): LvimTestPosition[]?  full override
---@field build         fun(req: LvimTestRunRequest): LvimTestSpec?  argv/cwd/env for a run
---@field stream?       fun(line: string, ctx: table): table<string, LvimTestResult>?  incremental
---@field parse         fun(ctx: table): table<string, LvimTestResult>  final result parse
---@field debug?        fun(req: LvimTestRunRequest): table?  an lvim-dap configuration
---@field tools?        table<string, (string|fun(root: string): string?)[]>  binary strategies
---@field toolchain_provider? string  lvim-lang provider whose toolchain resolves this adapter's tool
---@field health?       fun(h: table)  extra :checkhealth section

---@class LvimTestResult
---@field status  "passed"|"failed"|"skipped"|"running"
---@field short?  string    One-line failure summary (eol virt text / tree detail)
---@field output? string[]  This position's extracted output lines
---@field errors? { message: string, path?: string, line?: integer }[]  diagnostics input

local M = {}

---@type table<string, LvimTestAdapter>
local adapters = {}

---@type table<string, LvimTestAdapter[]>  filetype → adapters (in registration order)
local by_ft = {}

--- Register (or replace) an adapter and (re)index its filetypes. Safe in any load order and at
--- runtime — the ft index is rebuilt from the current set, so a late registration is picked up by
--- the next `for_buffer` without any restart.
---@param adapter LvimTestAdapter
---@return nil
function M.register(adapter)
    if type(adapter) ~= "table" or type(adapter.name) ~= "string" then
        return
    end
    adapters[adapter.name] = adapter
    by_ft = {}
    for _, a in pairs(adapters) do
        for _, ft in ipairs(a.filetypes or {}) do
            local list = by_ft[ft] or {}
            list[#list + 1] = a
            by_ft[ft] = list
        end
    end
end

--- A registered adapter by name.
---@param name string
---@return LvimTestAdapter?
function M.get(name)
    return adapters[name]
end

--- Every registered adapter name (sorted).
---@return string[]
function M.names()
    local names = vim.tbl_keys(adapters)
    table.sort(names)
    return names
end

--- Resolve the adapter + project root that OWN a buffer: the first adapter registered for the
--- buffer's filetype whose root markers resolve upward from the file. Returns nil when no adapter
--- claims the filetype or no root marker is found.
---@param bufnr integer
---@return LvimTestAdapter?, string?
function M.for_buffer(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local ft = vim.bo[bufnr].filetype
    local list = by_ft[ft]
    if not list then
        return nil, nil
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        return nil, nil
    end
    for _, adapter in ipairs(list) do
        local root = vim.fs.root(path, adapter.root_markers)
        if root then
            return adapter, root
        end
    end
    return nil, nil
end

return M
