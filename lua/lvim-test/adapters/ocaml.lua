-- lvim-test.adapters.ocaml: the OCaml adapter (dune's `runtest`).
-- OCaml has no single test protocol and dune exposes NO per-test name filter — alcotest / ounit /
-- inline expect-tests all register with dune's `runtest` alias, run as a whole, and print
-- FRAMEWORK-SPECIFIC output (there is no machine-readable, cross-framework result stream). So this
-- adapter runs `dune runtest` scoped to the DIRECTORY of the requested target (the finest granularity
-- dune gives) and maps results COARSELY: a clean exit passes every covered test position, a failing
-- run marks the covered file positions failed with the dune/compiler output (the location line
-- `File "f.ml", line L, characters C-C:` → a diagnostic). Discovery (for the summary tree) surfaces
-- top-level `let test_… ` bindings via treesitter, nested under `module` namespaces. Per-test
-- isolation would require inventing a per-framework runner — a kludge — so it is deliberately absent.
--
-- When lvim-lang is installed and its OCaml provider is active, the `dune` binary is resolved through
-- `lvim-lang.core.toolchain` first (honouring the active opam switch), then PATH. lvim-test works
-- fully without lvim-lang.
--
---@module "lvim-test.adapters.ocaml"

local config = require("lvim-test.config")

-- `module` items → namespaces; top-level `let test_… ` bindings → tests. Nesting is derived from
-- range containment by the discovery engine. The `#lua-match?` keeps only test-prefixed bindings.
local QUERY = [[
(module_definition
  (module_binding (module_name) @namespace.name)) @namespace.definition
((value_definition
  (let_binding pattern: (value_name) @test.name)) @test.definition
  (#lua-match? @test.name "^test"))
]]

local M = {}

--- The `dune` binary for a root: the lvim-lang OCaml toolchain when active, else PATH, else the name.
---@param root string
---@return string
local function dune_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("ocaml", "dune", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("dune")
    return p ~= "" and p or "dune"
end

--- The directory (relative to `root`) that owns a requested target — dune's runtest scope. A file /
--- test / namespace target scopes to its file's directory; a dir target to the dir; nothing → the
--- whole project (".").
---@param root string
---@param targets LvimTestPosition[]
---@return string
local function scope_dir(root, targets)
    for _, t in ipairs(targets) do
        local path = t.path
        if path and path ~= "" then
            local dir = (t.kind == "dir") and path or vim.fs.dirname(path)
            if vim.startswith(dir, root) then
                local rel = dir:sub(#root + 2)
                return rel == "" and "." or rel
            end
            return dir
        end
    end
    return "."
end

---@type LvimTestAdapter
local adapter = {
    name = "ocaml",
    filetypes = { "ocaml" },
    root_markers = { "dune-project", ".git" },
    lang = "ocaml",
    query = QUERY,
    toolchain_provider = "ocaml",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        -- dune tests conventionally live under a `test/` or `tests/` dir and/or are named
        -- `test_*.ml` / `*_test.ml`; the treesitter query then surfaces only files with test bindings.
        if path:match("%.mli?$") == nil then
            return false
        end
        return path:match("/tests?/") ~= nil
            or path:match("test_[^/]*%.mli?$") ~= nil
            or path:match("_test%.mli?$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local rel = scope_dir(root, req.targets)

        -- Every covered test/file position (so the coarse result mapping can address them).
        ---@type string[]
        local covered_tests, covered_files = {}, {}
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                covered_tests[#covered_tests + 1] = pos.id
            elseif pos.kind == "file" then
                covered_files[#covered_files + 1] = pos.id
            end
        end

        local a = config.adapters.ocaml or {}
        local cmd = { dune_bin(root), "runtest", rel, "--force" }
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            -- OCaml/dune two-line diagnostics → one quickfix entry.
            matcher = table.concat({
                [[%EFile "%f"\, line %l\, characters %c-%*\d:]],
                [[%WFile "%f"\, line %l\, characters %c-%*\d:]],
                [[%ZError: %m]],
                [[%C%m]],
            }, ","),
            context = { tests = covered_tests, files = covered_files },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context or {}
        local out = {}
        local failed = ctx.exit_code and ctx.exit_code ~= 0

        if not failed then
            -- Clean run: every covered test passed (dune gives no per-test breakdown to do better).
            for _, id in ipairs(c.tests or {}) do
                out[id] = { status = "passed" }
            end
            return out
        end

        -- Failing run: attach the first `File "…", line N` diagnostic and mark the covered FILE
        -- positions failed with the output — dune cannot attribute a failure to a single test.
        local errors
        for _, l in ipairs(ctx.lines or {}) do
            local file, lnum = l:match('^File "(.-)"%, line (%d+)')
            if file then
                errors = { { message = vim.trim(l), path = file, line = tonumber(lnum) } }
                break
            end
        end
        for _, id in ipairs(c.files or {}) do
            out[id] = { status = "failed", short = "dune runtest failed", output = ctx.lines, errors = errors }
        end
        -- Nothing to address (no discovered file positions) → mark covered tests failed.
        if not next(out) then
            for _, id in ipairs(c.tests or {}) do
                out[id] = { status = "failed", short = "dune runtest failed", output = ctx.lines, errors = errors }
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("dune") == "" then
            h.warn("dune not found on PATH")
        else
            h.ok("dune: " .. vim.fn.exepath("dune"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
