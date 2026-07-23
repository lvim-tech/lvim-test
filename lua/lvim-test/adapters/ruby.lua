-- lvim-test.adapters.ruby: the Ruby (RSpec) adapter.
-- Discovers RSpec examples (`it` / `specify` / `example` / `scenario` / `its`) and their enclosing
-- groups (`describe` / `context` / `feature` / `shared_examples`) via a treesitter query, and runs
-- them through `rspec` (prefixed with `bundle exec` when the project has a Gemfile). RSpec does not
-- stream a per-example protocol on stdout usefully, but it writes a machine-readable JSON report with
-- `--format json --out <file>`; so results are parsed at the END from that report (progress stays on
-- the panel), each example mapped back onto its position by (relative file path, line number) — the
-- line RSpec records for a `it`/`describe` block is exactly the discovered `call` node's start line.
-- A failing example's `exception.message` + backtrace give the short reason + a `file.rb:LINE`
-- diagnostic; a load/syntax failure marks the covered file positions failed.
--
-- When lvim-lang is installed and its Ruby provider is active, the `rspec` / `bundle` binaries are
-- resolved through `lvim-lang.core.toolchain` first (honouring the version manager), then PATH.
-- Per-example debugging is delegated to lvim-lang's Ruby DAP (rdbg). lvim-test works fully without
-- lvim-lang.
--
---@module "lvim-test.adapters.ruby"

local config = require("lvim-test.config")

-- `describe`/`context`/… calls → namespaces; `it`/`specify`/… calls → tests. The first argument (a
-- description string, or a class const for `describe Foo`) is the display name; `#any-of?` keeps only
-- RSpec's DSL methods so ordinary method calls with blocks are ignored.
local QUERY = [[
(call
  method: (identifier) @_ns
  arguments: (argument_list . (_) @namespace.name)
  (#any-of? @_ns "describe" "context" "feature" "shared_examples" "shared_context" "shared_examples_for")) @namespace.definition

(call
  method: (identifier) @_t
  arguments: (argument_list . (_) @test.name)
  (#any-of? @_t "it" "specify" "example" "scenario" "its")) @test.definition
]]

local M = {}

--- The rspec command prefix for a root: `bundle exec rspec` when a Gemfile + bundler resolve, else
--- the resolved `rspec` binary (lvim-lang toolchain when active, then PATH, then the bare name).
---@param root string
---@return string[]
local function rspec_cmd(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    local function resolve(tool)
        if ok and tc and tc.resolve then
            local r = tc.resolve("ruby", tool, root)
            if r and r ~= "" then
                return r
            end
        end
        return nil
    end
    if vim.fn.filereadable(vim.fs.joinpath(root, "Gemfile")) == 1 then
        local bundle = resolve("bundle") or (vim.fn.exepath("bundle") ~= "" and vim.fn.exepath("bundle") or nil)
        if bundle then
            return { bundle, "exec", "rspec" }
        end
    end
    local rspec = resolve("rspec")
    if not rspec then
        local p = vim.fn.exepath("rspec")
        rspec = p ~= "" and p or "rspec"
    end
    return { rspec }
end

--- The project-relative path of `abs` (leading `./` stripped), for keying against RSpec's reported
--- `file_path` (`./spec/foo_spec.rb`).
---@param root string
---@param abs string
---@return string
local function rel_path(root, abs)
    local rel = vim.fs.relpath(root, abs) or vim.fn.fnamemodify(abs, ":t")
    return (rel:gsub("^%./", ""))
end

--- A position's 1-based definition line (the `it` / `describe` block line RSpec records), or nil.
---@param pos LvimTestPosition
---@return integer|nil
local function pos_line(pos)
    return pos.range and (pos.range[1] + 1) or nil
end

---@type LvimTestAdapter
local adapter = {
    name = "ruby",
    filetypes = { "ruby" },
    root_markers = { "Gemfile", ".rspec", "spec", ".git" },
    lang = "ruby",
    query = QUERY,
    toolchain_provider = "ruby",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("_spec%.rb$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local args, seen = {}, {}
        ---@type table<string, string>  "<rel_path>:<line>" → position id
        local by_loc = {}

        local function add_arg(a)
            if not seen[a] then
                seen[a] = true
                args[#args + 1] = a
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" or t.kind == "namespace" then
                -- RSpec addresses an example / group by `path:line` — the block's start line.
                local line = pos_line(t)
                add_arg(line and (rel_path(root, t.path) .. ":" .. line) or rel_path(root, t.path))
            elseif t.kind == "file" then
                add_arg(rel_path(root, t.path))
            end -- dir: no arg → run the whole suite from the root
        end
        -- Map every covered test by (relative path, line) for result resolution.
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                local line = pos_line(pos)
                if line then
                    by_loc[rel_path(root, pos.path) .. ":" .. line] = pos.id
                end
            end
        end

        -- RSpec writes the machine-readable report here (progress stays on the panel via a second
        -- formatter) — parsed + removed in parse(). A per-run temp file avoids stale results.
        local results_file = vim.fn.tempname()

        local a = config.adapters.ruby or {}
        local cmd = rspec_cmd(root)
        vim.list_extend(cmd, { "--format", "progress", "--format", "json", "--out", results_file })
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, args)
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "generic",
            context = { by_loc = by_loc, results_file = results_file },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        local file = c.results_file

        local report
        if file and vim.fn.filereadable(file) == 1 then
            local text = table.concat(vim.fn.readfile(file), "\n")
            local ok, decoded = pcall(vim.json.decode, text)
            if ok and type(decoded) == "table" then
                report = decoded
            end
            os.remove(file)
        end

        for _, ex in ipairs((report and report.examples) or {}) do
            local fp = type(ex.file_path) == "string" and (ex.file_path:gsub("^%./", "")) or nil
            local id = fp and ex.line_number and c.by_loc[fp .. ":" .. ex.line_number] or nil
            if id then
                if ex.status == "passed" then
                    out[id] = { status = "passed" }
                elseif ex.status == "pending" then
                    out[id] = { status = "skipped", short = ex.pending_message and vim.trim(ex.pending_message) or nil }
                elseif ex.status == "failed" then
                    local exc = ex.exception or {}
                    local short = exc.message and vim.trim(vim.split(exc.message, "\n")[1] or exc.message) or "failed"
                    local res = { status = "failed", short = short }
                    -- A `file.rb:LINE` from the backtrace matching this example's file → a diagnostic.
                    local pos = (ctx.scope_map or {})[id]
                    local tail = pos and vim.fn.fnamemodify(pos.path, ":t")
                    for _, bl in ipairs(exc.backtrace or {}) do
                        local lnum = tail and bl:match(vim.pesc(tail) .. ":(%d+)")
                        if lnum then
                            res.errors = { { message = short, path = pos.path, line = tonumber(lnum) } }
                            break
                        end
                    end
                    res.output = exc.backtrace
                    out[id] = res
                end
            end
        end

        -- No example mapped and the run failed → a load / syntax error. Mark the covered file
        -- positions failed so the error is visible instead of a silent "skipped".
        if next(out) == nil and ctx.exit_code and ctx.exit_code ~= 0 then
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] = { status = "failed", short = "rspec run failed", output = ctx.lines }
                end
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return table?
    debug = function(req)
        local ok = pcall(require, "lvim-lang.providers.ruby.dap")
        if not ok then
            return nil
        end
        local t = req.targets[1]
        if not t then
            return nil
        end
        local line = pos_line(t)
        local script = line and (t.path .. ":" .. line) or t.path
        local command = "rspec"
        if vim.fn.filereadable(vim.fs.joinpath(req.root, "Gemfile")) == 1 then
            command = "bundle exec rspec"
        end
        return {
            type = "ruby",
            request = "attach",
            name = "lvim-test: " .. t.name,
            command = command,
            script = script,
            cwd = req.root,
        }
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("rspec") ~= "" or vim.fn.exepath("bundle") ~= "" then
            h.ok("rspec: " .. (vim.fn.exepath("rspec") ~= "" and vim.fn.exepath("rspec") or "via bundle exec"))
        else
            h.info("no rspec / bundle on PATH — run through the project bundle (`bundle exec rspec`)")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
