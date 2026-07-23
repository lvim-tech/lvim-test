-- lvim-test.adapters.perl: the Perl adapter (Test::More / prove).
-- Perl's runnable unit is the `.t` test FILE (prove runs files; the individual `ok()` / `is()`
-- assertions inside are not named, treesitter-discoverable blocks), so this adapter is FILE-granular:
-- it discovers `t/**/*.t` files and runs them through `prove -v`, marking each file passed / failed from
-- prove's per-file result line (`t/foo.t … ok` vs `… Failed`).
--
-- When lvim-lang is installed and its Perl provider is active, `perl` is resolved through
-- `lvim-lang.core.toolchain`; `prove` comes from PATH. lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.perl"

local config = require("lvim-test.config")

---@type LvimTestAdapter
local adapter = {
    name = "perl",
    filetypes = { "perl" },
    lang = "perl",
    root_markers = { "Makefile.PL", "Build.PL", "dist.ini", "cpanfile", ".git" },
    toolchain_provider = "perl",
    -- No treesitter query: a `.t` file is the test unit (flat ok()/is() assertions are not named blocks).

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        return path:match("[/\\]t[/\\].*%.t$") ~= nil or path:match("%.t$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local a = config.adapters.perl or {}
        local files, seen = {}, {}
        for _, t in ipairs(req.targets) do
            if t.path and not seen[t.path] then
                seen[t.path] = true
                files[#files + 1] = t.path
            end
        end
        local file_ids = {}
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "file" then
                file_ids[vim.fn.fnamemodify(pos.path, ":.")] = pos.id
                file_ids[pos.path] = pos.id
            end
        end
        -- `prove -lr` includes lib/ + recurses; `-v` gives the per-file result lines.
        local cmd = { "prove", "-lrv" }
        if #files > 0 then
            vim.list_extend(cmd, files)
        else
            cmd[#cmd + 1] = "t"
        end
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})
        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            context = { file_ids = file_ids },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        -- prove per-file result: `t/foo.t ....... ok` / `t/foo.t ....... Failed …`.
        for _, line in ipairs(ctx.lines or {}) do
            local file = line:match("^(%S+%.t)%s")
            if file then
                local id = c.file_ids[file] or c.file_ids[vim.fs.normalize(vim.fs.joinpath(ctx.root, file))]
                if id then
                    if line:match("%.%s+ok%s*$") or line:match("%.%s+ok%s") then
                        out[id] = { status = "passed" }
                    elseif line:match("Failed") or line:match("Dubious") then
                        out[id] = { status = "failed", short = vim.trim(line) }
                    end
                end
            end
        end
        return out
    end,

    ---@param h table
    health = function(h)
        if vim.fn.exepath("prove") == "" then
            h.warn("prove not found on PATH (comes with Perl)")
        else
            h.ok("prove: " .. vim.fn.exepath("prove"))
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
