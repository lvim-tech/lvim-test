-- lvim-test.project: per-project configuration overrides.
-- Reads a pure-data override table from the unified ".lvim" namespace
-- (<root>/.lvim/test/config.lua) and merges it over the global config for THAT project — so a
-- repo can pin its own runner args / environment without touching the user's setup(). The file
-- returns a partial config table, e.g.
--   return { adapters = { go = { args = { "-race" } } }, run = { env = { CI = "1" } } }
-- It is loaded in a protected call (never trusted to run side effects) and cached against its
-- mtime, so a run does not re-read an unchanged file.
--
---@module "lvim-test.project"

local config = require("lvim-test.config")

local M = {}

---@type table<string, { stamp: string, data: table }>
local cache = {}

--- Absolute path to a root's override file under the unified ".lvim" namespace.
---@param root string
---@return string
function M.path(root)
    return table.concat({ root, config.project.dir, config.project.file }, "/")
end

--- The override table for a root (empty when the file is absent / invalid). Cached by mtime.
---@param root string
---@return table
function M.overrides(root)
    local path = M.path(root)
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end
    local st = vim.uv.fs_stat(path)
    local stamp = st and st.mtime and (st.mtime.sec .. "." .. (st.mtime.nsec or 0)) or "0"
    local hit = cache[root]
    if hit and hit.stamp == stamp then
        return hit.data
    end
    local ok, chunk = pcall(dofile, path)
    local data = (ok and type(chunk) == "table") and chunk or {}
    cache[root] = { stamp = stamp, data = data }
    return data
end

--- Fold a root's overrides into a run REQUEST: the project's `run.env` and the adapter's own
--- `env` become extra request env; the adapter's `args` are prepended to the request's extra args.
--- This carries the common per-project knobs through the request the adapter already consumes —
--- no adapter changes, no global mutation.
---@param req LvimTestRunRequest
---@return nil
function M.apply(req)
    local ov = M.overrides(req.root)
    if not next(ov) then
        return
    end
    local env = vim.tbl_extend("force", {}, req.env or {})
    if type(ov.run) == "table" and type(ov.run.env) == "table" then
        env = vim.tbl_extend("force", env, ov.run.env)
    end
    local a = type(ov.adapters) == "table" and ov.adapters[req.adapter.name]
    if type(a) == "table" then
        if type(a.env) == "table" then
            env = vim.tbl_extend("force", env, a.env)
        end
        if type(a.args) == "table" and #a.args > 0 then
            local extra = {}
            vim.list_extend(extra, a.args)
            vim.list_extend(extra, req.extra_args or {})
            req.extra_args = extra
        end
    end
    if next(env) then
        req.env = env
    end
end

return M
