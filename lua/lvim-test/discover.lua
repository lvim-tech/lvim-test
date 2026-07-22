-- lvim-test.discover: lazy, cached test discovery.
-- Turns a source FILE into a `position` map (the file node + its namespace/test children) using
-- the owning adapter's treesitter QUERY (capture convention below), or the adapter's own
-- `discover` override when a query cannot express it. Nesting is derived from range containment,
-- so an adapter only has to tag the name + definition nodes — the tree falls out geometrically.
--
-- Everything is LAZY and CACHED: a file is parsed only when it is opened / run / expanded, and the
-- result is cached against a change stamp (buffer changedtick when loaded, file mtime otherwise),
-- so re-running a file does not re-parse an unchanged one. The project WALK (candidate file
-- listing for the summary tree) is separate + cheap: a `vim.fs` dir walk gated by the adapter's
-- `is_test_file` name test — no parsing until a file is actually needed.
--
-- Capture convention (ours): `@test.name` + `@test.definition`, `@namespace.name` +
-- `@namespace.definition`. The `.definition` node gives the range (and drives nesting); the
-- `.name` node's text is the display name (surrounding string quotes stripped).
--
---@module "lvim-test.discover"

local config = require("lvim-test.config")
local position = require("lvim-test.position")

---@class LvimTestDiscoverCtx
---@field adapter LvimTestAdapter
---@field path    string   the file being discovered (abs)
---@field root    string   the project root
---@field bufnr?  integer  the loaded buffer for `path`, when any
---@field source  string|integer  parser source: the content string, or the bufnr
---@field lang    string   the treesitter language

local M = {}

---@type table<string, { stamp: string, map: table<string, LvimTestPosition> }>
local cache = {}

---@type table<string, string[]>  root → cached candidate file list (project walk)
local walk_cache = {}

--- The change stamp for a file: the loaded buffer's changedtick when it is loaded (edits
--- invalidate), else the file's mtime (external changes invalidate).
---@param path string
---@param bufnr? integer
---@return string
local function stamp_of(path, bufnr)
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        return "buf:" .. vim.api.nvim_buf_get_changedtick(bufnr)
    end
    local st = vim.uv.fs_stat(path)
    return "file:" .. (st and st.mtime and (st.mtime.sec .. "." .. (st.mtime.nsec or 0)) or "0")
end

--- Whether an OUTER range strictly encloses an INNER range (used for namespace/test nesting).
---@param outer integer[]  { srow, scol, erow, ecol }
---@param inner integer[]
---@return boolean
local function encloses(outer, inner)
    if outer[1] > inner[1] or outer[3] < inner[3] then
        return false
    end
    if outer[1] == inner[1] and outer[3] == inner[3] then
        return false -- identical span is not containment
    end
    return true
end

--- Run the adapter's query over a source tree and collect raw `{ kind, name, range }` entries.
---@param ctx LvimTestDiscoverCtx
---@param query_str string
---@return { kind: LvimTestPosKind, name: string, range: integer[] }[]
local function run_query(ctx, query_str)
    local ok_parse, query = pcall(vim.treesitter.query.parse, ctx.lang, query_str)
    if not ok_parse or not query then
        return {}
    end
    local parser
    if type(ctx.source) == "number" then
        parser = vim.treesitter.get_parser(ctx.source, ctx.lang)
    else
        parser = vim.treesitter.get_string_parser(ctx.source, ctx.lang)
    end
    if not parser then
        return {}
    end
    local tree = (parser:parse() or {})[1]
    if not tree then
        return {}
    end
    local raw = {}
    for _, match in query:iter_matches(tree:root(), ctx.source, 0, -1) do
        local kind, def_node, name_node
        for id, nodes in pairs(match) do
            local cap = query.captures[id]
            local node = type(nodes) == "table" and nodes[#nodes] or nodes
            local base, part = cap:match("^(%w+)%.(%w+)$")
            if part == "definition" then
                kind = (base == "namespace") and "namespace" or "test"
                def_node = node
            elseif part == "name" then
                name_node = node
            end
        end
        if def_node then
            local name = name_node and vim.treesitter.get_node_text(name_node, ctx.source) or "?"
            name = name:gsub("^[\"`']", ""):gsub("[\"`']$", "") -- strip a surrounding string quote
            local sr, sc, er, ec = def_node:range()
            raw[#raw + 1] = { kind = kind, name = name, range = { sr, sc, er, ec } }
        end
    end
    return raw
end

--- Assemble raw discovery entries into a full position map for a file: a `file` root plus its
--- namespace/test children linked by range containment (innermost encloser = parent, else file).
---@param path string
---@param raw { kind: LvimTestPosKind, name: string, range: integer[] }[]
---@return table<string, LvimTestPosition>
local function assemble(path, raw)
    ---@type table<string, LvimTestPosition>
    local map = {}
    map[path] = { id = path, kind = "file", name = vim.fn.fnamemodify(path, ":t"), path = path, children = {} }

    -- Outer-first order (start asc, then wider span first) so a container is always built before
    -- what it contains; the innermost enclosing already-built node becomes the parent.
    table.sort(raw, function(a, b)
        if a.range[1] ~= b.range[1] then
            return a.range[1] < b.range[1]
        end
        return a.range[3] > b.range[3]
    end)

    ---@type { id: string, range: integer[] }[]
    local built = {}
    for _, item in ipairs(raw) do
        local parent_id = path
        for i = #built, 1, -1 do
            if encloses(built[i].range, item.range) then
                parent_id = built[i].id
                break
            end
        end
        local id = position.id(parent_id, item.name)
        map[id] = {
            id = id,
            kind = item.kind,
            name = item.name,
            path = path,
            range = item.range,
            parent = parent_id,
            children = {},
        }
        built[#built + 1] = { id = id, range = item.range }
    end
    return position.link(map)
end

--- Discover the positions in ONE file (cached against its change stamp). Returns a position map
--- (`id → LvimTestPosition`) that always contains the file position itself. An adapter `discover`
--- override wins over the query path.
---@param adapter LvimTestAdapter
---@param path string   abs file path
---@param bufnr? integer  the loaded buffer for `path`, when any
---@return table<string, LvimTestPosition>
function M.file(adapter, path, bufnr)
    local stamp = stamp_of(path, bufnr)
    local hit = cache[path]
    if hit and hit.stamp == stamp then
        return hit.map
    end

    local lang = adapter.lang or (bufnr and vim.bo[bufnr].filetype) or vim.filetype.match({ filename = path }) or ""
    local source
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        source = bufnr
    else
        local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
        source = table.concat(lines, "\n")
    end

    ---@type LvimTestDiscoverCtx
    local ctx = { adapter = adapter, path = path, root = "", bufnr = bufnr, source = source, lang = lang }

    local map
    if adapter.discover then
        local list = adapter.discover(ctx) or {}
        map =
            { [path] = { id = path, kind = "file", name = vim.fn.fnamemodify(path, ":t"), path = path, children = {} } }
        for _, pos in ipairs(list) do
            map[pos.id] = pos
        end
        map = position.link(map)
    else
        local query_str = adapter.query
        if type(query_str) == "function" then
            query_str = query_str("")
        end
        map = assemble(path, type(query_str) == "string" and run_query(ctx, query_str) or {})
    end

    cache[path] = { stamp = stamp, map = map }
    return map
end

--- Drop the cached discovery for a file (or all files when `path` is nil), forcing a re-parse.
---@param path? string
---@return nil
function M.invalidate(path)
    if path then
        cache[path] = nil
    else
        cache = {}
        walk_cache = {} -- a full refresh re-scans the project file list too
    end
end

--- Drop the cached project walk for a root (or all roots), forcing a re-scan on the next walk.
---@param root? string
---@return nil
function M.invalidate_walk(root)
    if root then
        walk_cache[root] = nil
    else
        walk_cache = {}
    end
end

--- Walk a project root for candidate test files (name test only — no parsing). CACHED per root: a
--- filesystem scan of a big project is far too expensive to repeat on every result event (it would
--- block the UI, freezing spinners) — the list changes only when files are added/removed, so it is
--- re-scanned on `invalidate_walk` (a save of a NEW test file, `:LvimTest refresh`), not per repaint.
--- Prunes `config.discovery.ignore_dirs` and stops at `config.discovery.max_files`.
---@param adapter LvimTestAdapter
---@param root string
---@return string[]  abs file paths
function M.walk(adapter, root)
    if walk_cache[root] then
        return walk_cache[root]
    end
    local ignore = {}
    for _, d in ipairs(config.discovery.ignore_dirs or {}) do
        ignore[d] = true
    end
    local files, cap = {}, config.discovery.max_files or 5000
    for name, kind in
        vim.fs.dir(root, {
            depth = 32,
            skip = function(dirname)
                return not ignore[dirname]
            end,
        })
    do
        if kind == "file" then
            local path = root .. "/" .. name
            if adapter.is_test_file(path, root) then
                files[#files + 1] = path
                if #files >= cap then
                    break
                end
            end
        end
    end
    walk_cache[root] = files
    return files
end

--- Discover EVERY test file under a root into one merged position map (for a whole-suite run).
---@param adapter LvimTestAdapter
---@param root string
---@return table<string, LvimTestPosition>
function M.root(adapter, root)
    local merged = {}
    for _, path in ipairs(M.walk(adapter, root)) do
        local bufnr = vim.fn.bufnr(path)
        for id, pos in pairs(M.file(adapter, path, bufnr ~= -1 and bufnr or nil)) do
            merged[id] = pos
        end
    end
    return merged
end

return M
