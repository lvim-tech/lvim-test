-- lvim-test.adapters.haskell: the Haskell (hspec) adapter.
-- Discovers hspec examples with a custom, GRAMMAR-INDEPENDENT scan: hspec spec trees are ordinary
-- function applications (`describe "…" $ do`, `it "…" $ do`) whose nesting is expressed by
-- indentation, so an indentation-stacked line scan recovers the `describe`/`context` namespaces and
-- the `it`/`specify`/`prop` examples reliably without depending on the tree-sitter-haskell node names.
-- Runs go through the project's build tool — Stack (`stack test`) or Cabal (`cabal test`), auto-detected
-- per root — with hspec's `--match "/describe/…/it/"` filter selecting the requested examples (passed via
-- Stack's `--test-arguments` string, or Cabal's repeatable, space-safe `--test-option=`).
--
-- hspec has no per-test machine protocol, so results are parsed from its console output at the end: the
-- `N examples, M failures` summary proves the suite ran (covered examples not named in the `Failures:`
-- section are then passed), and each `n) <describe> <…> <it>` failure entry maps back onto its position
-- by the space-joined requirement path, attaching hspec's short reason + a `File.hs:LINE` diagnostic. A
-- compile / configuration failure (tests never ran) marks the covered files failed.
--
-- When lvim-lang is installed and its Haskell provider is active, the build tool binary is resolved
-- through `lvim-lang.core.toolchain` first (honouring GHCup / a version manager), then PATH. lvim-test
-- works fully without lvim-lang.
--
---@module "lvim-test.adapters.haskell"

local config = require("lvim-test.config")
local position = require("lvim-test.position")
local results = require("lvim-test.results")

-- hspec spec-tree combinators: describe/context open a NAMESPACE; it/specify/prop are EXAMPLES.
---@type table<string, "namespace"|"test">
local KW = {
    describe = "namespace",
    context = "namespace",
    fdescribe = "namespace",
    xdescribe = "namespace",
    fcontext = "namespace",
    xcontext = "namespace",
    it = "test",
    specify = "test",
    prop = "test",
    fit = "test",
    xit = "test",
    fspecify = "test",
    xspecify = "test",
}

-- Stack markers (any present → Stack); otherwise a `cabal.project` / `*.cabal` → Cabal.
local STACK_MARKERS = { "stack.yaml" }

--- The build tool for a root: "stack" (a stack.yaml) → "cabal" (cabal.project / a *.cabal) → nil.
---@param root string
---@return "stack"|"cabal"|nil
local function detect_tool(root)
    for _, m in ipairs(STACK_MARKERS) do
        if vim.fn.filereadable(vim.fs.joinpath(root, m)) == 1 then
            return "stack"
        end
    end
    if
        vim.fn.filereadable(vim.fs.joinpath(root, "cabal.project")) == 1
        or #vim.fn.glob(vim.fs.joinpath(root, "*.cabal"), true, true) > 0
    then
        return "cabal"
    end
    return nil
end

--- The build tool binary for a root: the lvim-lang Haskell toolchain when active, else PATH, else name.
---@param tool "stack"|"cabal"
---@param root string
---@return string
local function tool_bin(tool, root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("haskell", tool, root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath(tool)
    return p ~= "" and p or tool
end

--- Escape a literal position-id separator inside a name (the engine splits ids on it).
---@param name string
---@return string
local function esc(name)
    return (name:gsub(position.SEP, ":"))
end

--- The lines of `ctx.source` (a bufnr's live lines, or a decoded string).
---@param ctx LvimTestDiscoverCtx
---@return string[]
local function source_lines(ctx)
    if type(ctx.source) == "number" then
        return vim.api.nvim_buf_get_lines(ctx.source, 0, -1, false)
    end
    return vim.split(ctx.source or "", "\n", { plain = true })
end

--- A position's namespace lineage names (outermost → innermost), from the scope map's parent chain.
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string[]
local function ns_lineage(map, pos)
    local names = {}
    local p = pos.parent and map[pos.parent]
    while p and p.kind == "namespace" do
        table.insert(names, 1, p.name)
        p = p.parent and map[p.parent]
    end
    return names
end

--- The hspec `--match` slash path for a position (`/Math/adds numbers/`): its namespace lineage +
--- (for a test) its own name.
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function slash_path(map, pos)
    local parts = ns_lineage(map, pos)
    if pos.kind ~= "namespace" then
        parts[#parts + 1] = pos.name
    else
        parts[#parts + 1] = pos.name
    end
    return "/" .. table.concat(parts, "/") .. "/"
end

--- The space-joined requirement label hspec prints in its `Failures:` section (`Math adds numbers`).
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function space_label(map, pos)
    local parts = ns_lineage(map, pos)
    parts[#parts + 1] = pos.name
    return table.concat(parts, " ")
end

--- The build-tool argv tail passing hspec `--match <pattern>` for each pattern. Cabal uses the
--- repeatable `--test-option=` (each value its own argv — space-safe); Stack the single string form.
---@param tool "stack"|"cabal"
---@param patterns string[]
---@return string[]
local function filter_args(tool, patterns)
    if #patterns == 0 then
        return {}
    end
    if tool == "cabal" then
        local out = {}
        for _, p in ipairs(patterns) do
            out[#out + 1] = "--test-option=--match"
            out[#out + 1] = "--test-option=" .. p
        end
        return out
    end
    local pieces = {}
    for _, p in ipairs(patterns) do
        pieces[#pieces + 1] = "--match"
        pieces[#pieces + 1] = p
    end
    return { "--test-arguments", table.concat(pieces, " ") }
end

--- Normalize a hspec requirement label for matching (drop commas, collapse whitespace).
---@param s string
---@return string
local function norm(s)
    return vim.trim((s:gsub(",", " "):gsub("%s+", " ")))
end

---@type LvimTestAdapter
local adapter = {
    name = "haskell",
    filetypes = { "haskell" },
    root_markers = { "stack.yaml", "cabal.project", "package.yaml", ".git" },
    lang = "haskell",
    toolchain_provider = "haskell",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        local tail = path:match("[^/]+$") or path
        if tail:match("Spec%.l?hs$") or tail:match("Test%.l?hs$") then
            return true
        end
        return path:lower():match("/tests?/") ~= nil and path:match("%.l?hs$") ~= nil
    end,

    --- Custom discovery: an indentation-stacked scan of the hspec `describe`/`context`/`it`/… calls,
    --- independent of the tree-sitter-haskell grammar (which may not be installed and whose node names
    --- vary). Namespaces (describe/context) nest by indentation; examples (it/specify/prop) are leaves.
    ---@param ctx LvimTestDiscoverCtx
    ---@return LvimTestPosition[]
    discover = function(ctx)
        local lines = source_lines(ctx)
        local out = {}
        ---@type { indent: integer, id: string }[]  open namespaces, deepest last
        local stack = {}

        for i, line in ipairs(lines) do
            local indent, kw, name = line:match('^(%s*)(%a+)%s+"([^"]*)"')
            local kind = kw and KW[kw]
            if kind then
                local w = #indent
                -- Close namespaces at the same or a deeper indent (siblings / dedent).
                while #stack > 0 and stack[#stack].indent >= w do
                    table.remove(stack)
                end
                local parent = (#stack > 0 and stack[#stack].id) or ctx.path
                local id = position.id(parent, esc(name))
                -- Range: the header line through the end of its indented block (so cursor-nearest inside
                -- the body maps to this example / namespace).
                local erow = i
                for j = i + 1, #lines do
                    local l = lines[j]
                    if l:match("%S") and (#(l:match("^(%s*)") or "") <= w) then
                        break
                    end
                    erow = j
                end
                out[#out + 1] = {
                    id = id,
                    kind = kind,
                    name = name,
                    path = ctx.path,
                    range = { i - 1, w, erow, 0 }, -- 0-based, end-exclusive
                    parent = parent,
                    children = {},
                }
                if kind == "namespace" then
                    stack[#stack + 1] = { indent = w, id = id }
                end
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local tool = detect_tool(root)
        if not tool then
            return nil
        end

        local patterns, pat_seen = {}, {}
        ---@type table<string, string>  normalized space label → position id
        local by_label = {}
        ---@type table<string, string>  leaf example name → id (fallback)
        local by_leaf = {}

        local function add_pattern(p)
            if not pat_seen[p] then
                pat_seen[p] = true
                patterns[#patterns + 1] = p
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" or t.kind == "namespace" then
                add_pattern(slash_path(req.scope_map, t))
            elseif t.kind == "file" then
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and pos.path == t.path then
                        add_pattern(slash_path(req.scope_map, pos))
                    end
                end
            end -- dir: no filter → run everything
        end
        -- Map EVERY covered example for result resolution.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_label[norm(space_label(req.scope_map, pos))] = pos.id
                by_leaf[norm(pos.name)] = pos.id
            end
        end

        local a = config.adapters.haskell or {}
        local cmd = { tool_bin(tool, root), "test" }
        vim.list_extend(cmd, filter_args(tool, patterns))
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "generic",
            context = { tool = tool, by_label = by_label, by_leaf = by_leaf },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        local lines = ctx.lines or {}

        -- Did the suite actually run? hspec prints a `N examples, M failures` (or `N example, …`) summary.
        local ran, failures = false, 0
        for _, l in ipairs(lines) do
            local n = l:match("(%d+)%s+examples?,%s+%d+%s+failure")
            if n then
                ran = true
                failures = tonumber(l:match("examples?,%s+(%d+)%s+failure")) or 0
            end
        end

        -- Parse the `Failures:` section: `n) <requirement path>` … block until the next entry / summary.
        local cur_id, buf = nil, {}
        local function flush()
            if cur_id then
                local short, errors
                for _, l in ipairs(buf) do
                    local file, lnum = l:match("(%S+%.l?hs):(%d+):%d+")
                    if not file then
                        file, lnum = l:match("(%S+%.l?hs):(%d+)")
                    end
                    if file and not errors then
                        errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                    end
                    if not short then
                        local t = vim.trim(l)
                        if t ~= "" and not t:match("^%S+%.l?hs:%d+") then
                            short = t
                        end
                    end
                end
                out[cur_id] = {
                    status = "failed",
                    output = vim.list_extend({}, buf),
                    short = short or "example failed",
                    errors = errors,
                }
            end
            cur_id, buf = nil, {}
        end

        for _, line in ipairs(lines) do
            local n, label = line:match("^%s*(%d+)%)%s+(.+)$")
            if n and label then
                flush()
                -- The header may carry a `File.hs:line:col: ` location prefix — strip it before matching.
                label = label:gsub("^%S+%.l?hs:%d+:%d+:%s*", ""):gsub("^%S+%.l?hs:%d+:%s*", "")
                cur_id = c.by_label[norm(label)] or c.by_leaf[norm(label:match("[^%s]+$") or label)]
            elseif
                cur_id and (line:match("^%s*%d+ examples?,") or line:match("^Randomized") or line:match("^Finished"))
            then
                flush()
            elseif cur_id then
                buf[#buf + 1] = line
            end
        end
        flush()

        if ran then
            -- Every covered example that did NOT fail passed (hspec ran them; only failures are listed).
            for _, id in ipairs(ctx.covered or {}) do
                local pos = (ctx.scope_map or {})[id]
                if pos and pos.kind == "test" and not out[id] then
                    out[id] = { status = "passed" }
                end
            end
        elseif ctx.exit_code and ctx.exit_code ~= 0 then
            -- Tests never ran → a compile / configuration failure. Mark the covered files failed.
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] = { status = "failed", short = "build / test run failed", output = lines }
                end
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return table?
    debug = function(req)
        -- Per-test debugging is driven by lvim-lang's Haskell provider (haskell-debug-adapter); without
        -- it there is no in-editor debug config to hand back.
        local ok, hdap = pcall(require, "lvim-lang.providers.haskell.dap")
        if not ok or type(hdap.spec) ~= "function" then
            return nil
        end
        local t = req.targets[1]
        return {
            type = "haskell",
            request = "launch",
            name = "lvim-test: " .. (t and t.name or "haskell"),
            workspace = "${workspaceFolder}",
            startup = t and t.path or "${file}",
        }
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("stack") ~= "" or vim.fn.exepath("cabal") ~= "" then
            h.ok("build tool: " .. (vim.fn.exepath("stack") ~= "" and "stack" or "cabal"))
        else
            h.warn("no stack / cabal on PATH — install the Haskell toolchain via GHCup")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
