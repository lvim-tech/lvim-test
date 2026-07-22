-- lvim-test.adapters.rust: the Rust adapter.
-- Discovers `#[test]` (and `#[tokio::test]` / `#[rstest]` / …) functions via a treesitter query —
-- a function whose immediately-preceding attribute mentions `test` — nested under `mod` namespaces,
-- and runs them through `cargo test`. cargo test is not JSON by default, so results stream from its
-- human output: `test <path> ... ok|FAILED|ignored` flips a position's status live, and the trailing
-- `---- <path> stdout ----` failure blocks (parsed at the end) attach the panic message + a
-- `src/file.rs:LINE` diagnostic. A compile failure marks the covered file positions failed.
--
-- Test names are the full module path (`tests::it_works`), so a run filters with `-- --exact <path>`;
-- results map by that path, with the leaf function name as a fallback.
--
-- When lvim-lang is installed and its Rust provider is active, the `cargo` binary is resolved through
-- `lvim-lang.core.toolchain` first (honouring rustup / a version manager), then PATH. lvim-test works
-- fully without lvim-lang.
--
---@module "lvim-test.adapters.rust"

local config = require("lvim-test.config")

-- `#[test]`-attributed functions → tests; `mod` items → namespaces. The `.` anchor ties the attribute
-- to the function that immediately follows it; `#lua-match? "test"` keeps only test attributes.
local QUERY = [[
(mod_item name: (identifier) @namespace.name) @namespace.definition
((attribute_item) @_attr
  .
  (function_item name: (identifier) @test.name) @test.definition
  (#lua-match? @_attr "test"))
]]

local M = {}

--- The `cargo` binary for a root: the lvim-lang Rust toolchain when active, else PATH, else the name.
---@param root string
---@return string
local function cargo_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("rust", "cargo", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("cargo")
    return p ~= "" and p or "cargo"
end

--- A position's full module path (namespace lineage joined with `::`, then the function name) — the
--- name `cargo test` prints and filters on.
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function full_name(map, pos)
    local parts = { pos.name }
    local p = pos.parent and map[pos.parent]
    while p and p.kind == "namespace" do
        table.insert(parts, 1, p.name)
        p = p.parent and map[p.parent]
    end
    return table.concat(parts, "::")
end

---@type LvimTestAdapter
local adapter = {
    name = "rust",
    filetypes = { "rust" },
    root_markers = { "Cargo.toml", ".git" },
    lang = "rust",
    query = QUERY,
    toolchain_provider = "rust",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        -- Rust tests live anywhere (inline `#[cfg(test)] mod tests`, or under tests/): every `.rs`
        -- is a candidate; the treesitter query surfaces only files that actually contain tests.
        return path:match("%.rs$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local names, name_seen = {}, {}
        ---@type table<string, string>  full path → id
        local by_name = {}
        ---@type table<string, string>  leaf fn name → id (fallback)
        local by_leaf = {}

        local function add(pos)
            local fn = full_name(req.scope_map, pos)
            if not name_seen[fn] then
                name_seen[fn] = true
                names[#names + 1] = fn
            end
        end

        for _, t in ipairs(req.targets) do
            if t.kind == "test" then
                add(t)
            elseif t.kind == "namespace" then
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and pos.id:find(t.id, 1, true) == 1 then
                        add(pos)
                    end
                end
            elseif t.kind == "file" then
                for _, pos in pairs(req.scope_map) do
                    if pos.kind == "test" and pos.path == t.path then
                        add(pos)
                    end
                end
            end -- dir: no filter → run everything
        end
        -- Map EVERY covered test (so streamed lines for siblings still resolve).
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_name[full_name(req.scope_map, pos)] = pos.id
                by_leaf[pos.name] = pos.id
            end
        end

        local a = config.adapters.rust or {}
        local cmd = { cargo_bin(root), "test" }
        if a.features and a.features ~= "" then
            vim.list_extend(cmd, { "--features", a.features })
        end
        vim.list_extend(cmd, a.cargo_args or {})
        -- Harness args after `--`: exact-match the requested test paths (none → run the whole crate).
        cmd[#cmd + 1] = "--"
        cmd[#cmd + 1] = "--nocapture"
        if #names > 0 then
            cmd[#cmd + 1] = "--exact"
            vim.list_extend(cmd, names)
        end
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "rust",
            context = { by_name = by_name, by_leaf = by_leaf, cur = nil, output = {} },
        }
    end,

    ---@param line string
    ---@param ctx table
    ---@return table<string, LvimTestResult>?
    stream = function(line, ctx)
        local c = ctx.context
        -- Live status: `test <path> ... ok|FAILED|ignored`.
        local name, result = line:match("^test%s+(%S+)%s+%.%.%.%s+(%a+)")
        if name and result then
            local id = c.by_name[name] or c.by_leaf[name:match("[^:]+$") or name]
            if id then
                if result == "ok" then
                    return { [id] = { status = "passed" } }
                elseif result == "ignored" then
                    return { [id] = { status = "skipped" } }
                elseif result == "FAILED" then
                    return { [id] = { status = "failed" } }
                end
            end
        end
        return nil
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        -- Failure blocks: `---- <path> stdout ----` … up to the next `----` / blank / `failures:`.
        local cur_id, buf = nil, {}
        local function flush()
            if cur_id then
                local text = buf
                local short, errors
                for _, l in ipairs(text) do
                    local file, lnum = l:match("panicked at%s+(%S+%.rs):(%d+)")
                    if not file then
                        file, lnum = l:match("(%S+%.rs):(%d+):%d+")
                    end
                    if file and not errors then
                        errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                    end
                    if not short and l:match("panicked at") then
                        short = vim.trim(l:gsub("^.-panicked at%s*", ""))
                    end
                end
                out[cur_id] = {
                    status = "failed",
                    output = text,
                    short = short or (text[1] and vim.trim(text[1])) or "test failed",
                    errors = errors,
                }
            end
            cur_id, buf = nil, {}
        end
        for _, line in ipairs(ctx.lines or {}) do
            local name = line:match("^%-%-%-%-%s+(%S+)%s+stdout%s+%-%-%-%-")
            if name then
                flush()
                cur_id = c.by_name[name] or c.by_leaf[name:match("[^:]+$") or name]
            elseif cur_id and (line:match("^%-%-%-%-") or line:match("^failures:") or line:match("^test result:")) then
                flush()
            elseif cur_id then
                buf[#buf + 1] = line
            end
        end
        flush()

        -- Compile failure: the run failed and no covered test produced a status → mark the files.
        local produced = false
        for _, id in ipairs(ctx.covered or {}) do
            local r = require("lvim-test.results").get(ctx.root, id)
            if r and (r.status == "passed" or r.status == "failed") then
                produced = true
                break
            end
        end
        if not produced and ctx.exit_code and ctx.exit_code ~= 0 then
            local errors
            for _, l in ipairs(ctx.lines or {}) do
                local file, lnum = l:match("(%S+%.rs):(%d+):%d+")
                if file then
                    errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                    break
                end
            end
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] = { status = "failed", short = "build failed", output = ctx.lines, errors = errors }
                end
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("cargo") == "" then
            h.warn("cargo not found on PATH")
        else
            h.ok("cargo: " .. vim.fn.exepath("cargo"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
