-- lvim-test.adapters.php: the PHP (PHPUnit) adapter.
-- Discovers PHPUnit test methods (and their enclosing classes as namespaces) via a treesitter query
-- — a `method_declaration` whose name starts with `test`, OR one carrying a `#[Test]` attribute — and
-- runs them through the project's `phpunit`: the project-local `vendor/bin/phpunit` (where Composer
-- installs it) is preferred, then the lvim-lang PHP toolchain, then PATH. A single specific target is
-- selected with `--filter <name>`; otherwise the target FILES are passed and their tests run.
--
-- PHPUnit does not stream a per-test protocol we consume, but it writes a JUnit XML report
-- (`--log-junit <file>`). Results are parsed at the END from that report: each `<testcase>` maps back
-- onto its position by (simple class name, method), a `<failure>`/`<error>` giving the short reason +
-- a `File.php:LINE` diagnostic. There is no live streaming (statuses resolve when the run finishes); a
-- compile / bootstrap failure marks the covered files.
--
-- When lvim-lang is installed and its PHP provider is active, the `phpunit` / `php` binaries are still
-- resolved independently here, so lvim-test works fully without lvim-lang.
--
---@module "lvim-test.adapters.php"

local config = require("lvim-test.config")

-- `class_declaration` → namespace. A `method_declaration` is a test when its name starts with `test`
-- (the classic PHPUnit convention) OR it carries a `#[Test]` attribute (PHPUnit 10+ attribute style).
local QUERY = [[
(class_declaration
  name: (name) @namespace.name) @namespace.definition

(method_declaration
  name: (name) @test.name
  (#match? @test.name "^test")) @test.definition

(method_declaration
  (attribute_list (attribute_group (attribute (name) @_attr)))
  name: (name) @test.name
  (#match? @_attr "Test")) @test.definition
]]

local M = {}

--- The `phpunit` binary for a root: the project-local `vendor/bin/phpunit`, else the lvim-lang PHP
--- toolchain when active, else PATH, else the bare name.
---@param root string
---@return string
local function phpunit_bin(root)
    local vendor = vim.fs.joinpath(root, "vendor", "bin", "phpunit")
    if vim.fn.executable(vendor) == 1 then
        return vendor
    end
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("php", "phpunit", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("phpunit")
    return p ~= "" and p or "phpunit"
end

--- The `php` binary for a root: the lvim-lang PHP toolchain when active, else PATH, else the name.
---@param root string
---@return string
local function php_bin(root)
    local ok, tc = pcall(require, "lvim-lang.core.toolchain")
    if ok and tc and tc.resolve then
        local resolved = tc.resolve("php", "php", root)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local p = vim.fn.exepath("php")
    return p ~= "" and p or "php"
end

--- A position's outermost enclosing class (namespace) name, else the file basename without `.php`.
--- PHPUnit reports a testcase's class as its FQCN; we compare on the simple name.
---@param map table<string, LvimTestPosition>
---@param pos LvimTestPosition
---@return string
local function simple_class(map, pos)
    local cls
    ---@type LvimTestPosition?
    local p = pos
    while p do
        if p.kind == "namespace" then
            cls = p.name
        end
        p = p.parent and map[p.parent]
    end
    return cls or vim.fn.fnamemodify(pos.path, ":t:r")
end

--- Decode the XML entities PHPUnit escapes, and collapse to a single line.
---@param s string
---@return string
local function xml_unescape(s)
    s = s:gsub("&#10;", " "):gsub("&#13;", " "):gsub("&#9;", " ")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    return vim.trim((s:gsub("%s+", " ")))
end

--- Parse a PHPUnit JUnit XML report into
--- `{ class=<simple>, name=<method>, status, short?, trace?, file?, line? }` rows.
---@param text string
---@return { class: string, name: string, status: string, short?: string, trace: string, file?: string, line?: integer }[]
local function parse_report(text)
    local rows = {}
    local i = 1
    while true do
        local s = text:find("<testcase", i, true)
        if not s then
            break
        end
        local open_end = text:find(">", s, true)
        if not open_end then
            break
        end
        local opentag = text:sub(s, open_end)
        local name = opentag:match('name="(.-)"')
        local classname = opentag:match('class="(.-)"') or opentag:match('classname="(.-)"') or ""
        local cls = classname:match("[^\\]+$") or classname
        local file = opentag:match('file="(.-)"')
        local line = tonumber(opentag:match('line="(%d+)"'))
        local status, short, trace = "passed", nil, ""
        if opentag:sub(-2) == "/>" then
            i = open_end + 1
        else
            local close = text:find("</testcase>", open_end, true) or #text
            local body = text:sub(open_end + 1, close - 1)
            if body:find("<skipped", 1, true) then
                status = "skipped"
            elseif body:find("<failure", 1, true) or body:find("<error", 1, true) then
                status = "failed"
                short = body:match('<failure[^>]-message="(.-)"') or body:match('<error[^>]-message="(.-)"')
                if not short then
                    -- Message may be the tag's text content rather than a message="" attribute.
                    short = body:match("<failure[^>]*>(.-)</failure>") or body:match("<error[^>]*>(.-)</error>")
                end
                short = short and xml_unescape(short) or nil
                trace = body
            end
            i = close + #"</testcase>"
        end
        if name then
            rows[#rows + 1] =
                { class = cls, name = name, status = status, short = short, trace = trace, file = file, line = line }
        end
    end
    return rows
end

---@type LvimTestAdapter
local adapter = {
    name = "php",
    filetypes = { "php" },
    root_markers = { "composer.json", ".git" },
    lang = "php",
    query = QUERY,
    toolchain_provider = "php",

    ---@param path string
    ---@return boolean
    is_test_file = function(path, _root)
        local tail = vim.fn.fnamemodify(path, ":t")
        return tail:match("Test%.php$") ~= nil or tail:match("^Test.*%.php$") ~= nil
    end,

    ---@param req LvimTestRunRequest
    ---@return LvimTestSpec?
    build = function(req)
        local root = req.root
        local cmd = { phpunit_bin(root) }

        -- Files to run + an optional single filter. One specific test/namespace → `--filter <name>`;
        -- otherwise run the target files (or the whole project for a dir).
        local files, file_seen = {}, {}
        local specific = {}
        local function add_file(p)
            if p and not file_seen[p] then
                file_seen[p] = true
                files[#files + 1] = p
            end
        end
        for _, t in ipairs(req.targets) do
            if t.kind == "test" or t.kind == "namespace" then
                specific[#specific + 1] = t
                add_file(t.path)
            elseif t.kind == "file" then
                add_file(t.path)
            end -- dir: run everything
        end

        -- Result-mapping indexes: "<SimpleClass>#<method>" → id, and leaf method → id (fallback).
        ---@type table<string, string>
        local by_case = {}
        ---@type table<string, string>
        local by_leaf = {}
        for _, pos in pairs(req.scope_map) do
            if pos.kind == "test" then
                by_case[simple_class(req.scope_map, pos) .. "#" .. pos.name] = pos.id
                by_leaf[pos.name] = pos.id
            end
        end

        local a = config.adapters.php or {}
        vim.list_extend(cmd, files)
        if #specific == 1 then
            -- The method (test) or class (namespace) name — PHPUnit's --filter matches on it.
            cmd[#cmd + 1] = "--filter"
            cmd[#cmd + 1] = specific[1].name
        end
        local report = vim.fn.tempname() .. ".xml"
        vim.list_extend(cmd, { "--log-junit", report })
        vim.list_extend(cmd, a.args or {})
        vim.list_extend(cmd, req.extra_args or {})

        local env = vim.tbl_extend("force", {}, config.run.env or {}, a.env or {}, req.env or {})
        return {
            cmd = cmd,
            cwd = root,
            env = next(env) and env or nil,
            matcher = "generic",
            context = { report = report, by_case = by_case, by_leaf = by_leaf, root = root },
        }
    end,

    ---@param ctx table
    ---@return table<string, LvimTestResult>
    parse = function(ctx)
        local c = ctx.context
        local out = {}
        if vim.fn.filereadable(c.report) == 1 then
            local text = table.concat(vim.fn.readfile(c.report), "\n")
            pcall(vim.fn.delete, c.report)
            for _, row in ipairs(parse_report(text)) do
                local id = c.by_case[row.class .. "#" .. row.name] or c.by_leaf[row.name]
                if id then
                    local res = { status = row.status }
                    if row.status == "failed" then
                        res.short = row.short or "test failed"
                        res.output = vim.split(row.trace or "", "\n")
                        -- A file/line from the testcase attributes or the stack trace → a diagnostic.
                        local pos = (ctx.scope_map or {})[id]
                        local path = row.file
                        local lnum = row.line
                        if (not path or not lnum) and pos then
                            local tail = vim.fn.fnamemodify(pos.path, ":t")
                            local l = row.trace:match(vim.pesc(tail) .. ":(%d+)")
                            if l then
                                path, lnum = pos.path, tonumber(l)
                            end
                        end
                        if path and lnum then
                            res.errors = { { message = res.short, path = path, line = lnum } }
                        end
                    end
                    out[id] = res
                end
            end
        end

        -- No testcase mapped and the run failed → a bootstrap / autoload / syntax failure. Mark the
        -- covered file positions failed so the error is visible instead of silently "skipped".
        if next(out) == nil and ctx.exit_code and ctx.exit_code ~= 0 then
            for _, pos in pairs(ctx.scope_map or {}) do
                if pos.kind == "file" then
                    out[pos.id] = { status = "failed", short = "phpunit run failed", output = ctx.lines }
                end
            end
        end
        return out
    end,

    ---@param req LvimTestRunRequest
    ---@return table?
    debug = function(req)
        -- Per-test debugging launches phpunit under the CLI runtime with Xdebug triggered, driven by
        -- lvim-lang's PHP provider (php-debug-adapter). Without it there is no in-editor debug config.
        local ok = pcall(require, "lvim-lang.providers.php.dap")
        if not ok then
            return nil
        end
        local t = req.targets[1]
        if not t then
            return nil
        end
        local root = req.root
        local phpunit = phpunit_bin(root)
        if vim.fn.executable(phpunit) ~= 1 then
            return nil
        end
        local port = ((require("lvim-lang.config").providers or {}).php or {}).debug_port or 9003
        local args = { t.path }
        if t.kind == "test" or t.kind == "namespace" then
            args[#args + 1] = "--filter"
            args[#args + 1] = t.name
        end
        return {
            type = "php",
            name = "lvim-test: " .. t.name,
            request = "launch",
            program = phpunit,
            args = args,
            cwd = root,
            port = port,
            runtimeExecutable = php_bin(root),
            runtimeArgs = { "-dxdebug.start_with_request=yes" },
        }
    end,

    ---@param h table
    health = function(h)
        local root = vim.uv.cwd() or "."
        local bin = phpunit_bin(root)
        if vim.fn.executable(bin) == 1 then
            h.ok("phpunit: " .. bin)
        else
            h.info("phpunit not found — install it as a Composer dev dependency (vendor/bin/phpunit) or on PATH")
        end
    end,
}

require("lvim-test").register(adapter)

return adapter
