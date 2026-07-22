-- lvim-test.position: the position model — the universal tree of testable things.
-- A POSITION is one node in the dir → file → namespace → test hierarchy. Every runnable thing
-- (a whole directory, a file, a grouping construct, a single test) is a position with a STABLE
-- string id, so results, marks, signs and the summary tree all key off the same identity across
-- re-discovery. The engine treats ids as OPAQUE; adapters build them (and escape any literal
-- separator inside a name) — see `M.id`.
--
-- This module is pure data + geometry: it owns id construction, parent/child linking of a flat
-- position map, and the cursor-containment lookup (`nearest`). It runs no jobs and paints nothing.
--
---@module "lvim-test.position"

---@alias LvimTestPosKind "dir"|"file"|"namespace"|"test"

---@class LvimTestPosition
---@field id       string        Stable id: dir/file = abs path; ns/test = path .. "::" .. lineage
---@field kind     LvimTestPosKind
---@field name     string        Display name ("TestFoo", a describe block, the file tail)
---@field path     string        Owning file (abs) for ns/test/file; the dir itself for a dir
---@field range?   integer[]     { srow, scol, erow, ecol } 0-based, end-exclusive (nil for dir)
---@field parent?  string        Parent id
---@field children string[]      Child ids in source order
---@field data?    table         Adapter payload (e.g. the runner-side test name / escaping)

-- The id separator. A literal "::" inside a test name is escaped by the adapter before it reaches
-- here (the engine never inspects names), so splitting an id on SEP is unambiguous for callers
-- that need the lineage (the run grouping keys on the owning file/path, not on split lineage).
local SEP = "::"

local M = {}

M.SEP = SEP

--- Build a stable child id under a parent id from a (already-escaped) name segment.
---@param parent_id string  the owning file path, or a namespace/test id
---@param name string       the leaf segment (adapter-escaped: no literal SEP)
---@return string
function M.id(parent_id, name)
    return parent_id .. SEP .. name
end

--- Link a flat list of positions into a parent/child tree IN PLACE: fill each node's `children`
--- from the `parent` fields, in the order the list presents them (source order). Positions that
--- name a `parent` not present in the map are left as roots (their parent link is dropped) — a
--- discovery that returns only a file's inner positions still links cleanly under that file.
---@param map table<string, LvimTestPosition>  id → position (mutated: children filled)
---@return table<string, LvimTestPosition> map
function M.link(map)
    for _, pos in pairs(map) do
        pos.children = {}
    end
    -- Deterministic order: sort ids so children land in a stable sequence (adapters emit source
    -- order via range; ties fall back to id). We sort by (path, start row, id).
    local ids = vim.tbl_keys(map)
    table.sort(ids, function(a, b)
        local pa, pb = map[a], map[b]
        if pa.path ~= pb.path then
            return pa.path < pb.path
        end
        local ra = pa.range and pa.range[1] or -1
        local rb = pb.range and pb.range[1] or -1
        if ra ~= rb then
            return ra < rb
        end
        return a < b
    end)
    for _, id in ipairs(ids) do
        local pos = map[id]
        local parent = pos.parent and map[pos.parent]
        if parent then
            parent.children[#parent.children + 1] = id
        elseif pos.parent then
            pos.parent = nil -- dangling parent → treat as a root of this map
        end
    end
    return map
end

--- Whether a 0-based (row, col) cursor sits inside a position's range (end-exclusive).
---@param pos LvimTestPosition
---@param row integer  0-based
---@param col integer  0-based
---@return boolean
local function contains(pos, row, col)
    local r = pos.range
    if not r then
        return false
    end
    local sr, sc, er, ec = r[1], r[2], r[3], r[4]
    if row < sr or row > er then
        return false
    end
    if row == sr and col < sc then
        return false
    end
    if row == er and col > ec then
        return false
    end
    return true
end

--- The INNERMOST test/namespace position in `map` whose range contains the cursor, restricted to
--- the given file. "Innermost" = the smallest containing range (widest start, tightest end), so a
--- test inside a namespace wins over the namespace. nil when the cursor sits in no position.
---@param map table<string, LvimTestPosition>  id → position
---@param path string                          the buffer's file (abs)
---@param row integer                          0-based cursor row
---@param col integer                          0-based cursor col
---@return LvimTestPosition?
function M.nearest(map, path, row, col)
    ---@type LvimTestPosition?
    local best
    for _, pos in pairs(map) do
        if pos.path == path and (pos.kind == "test" or pos.kind == "namespace") and contains(pos, row, col) then
            if not best then
                best = pos
            else
                -- Prefer the tighter range: larger start row, then smaller span. Both ranges are
                -- present (contains() already rejected range-less positions), guarded for the checker.
                local br, pr = best.range, pos.range
                if br and pr and (pr[1] > br[1] or (pr[1] == br[1] and pr[3] < br[3])) then
                    best = pos
                end
            end
        end
    end
    return best
end

--- Collect a position id and all its descendant ids (the subtree the id runs).
---@param map table<string, LvimTestPosition>
---@param id string
---@return string[]
function M.subtree(map, id)
    local out = {}
    local function walk(nid)
        local pos = map[nid]
        if not pos then
            return
        end
        out[#out + 1] = nid
        for _, child in ipairs(pos.children or {}) do
            walk(child)
        end
    end
    walk(id)
    return out
end

return M
