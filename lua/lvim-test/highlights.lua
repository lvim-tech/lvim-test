-- lvim-test.highlights: the plugin's highlight groups, self-themed from the lvim-utils palette.
-- One semantic accent per test STATUS (passed=green, failed=red, running=yellow, skipped=blue)
-- plus the tree's structural accents (file/dir/namespace/adapter/marked/watching). Sign variants
-- carry ONLY the accent foreground (no bg) so the gutter dot blends into the buffer background
-- instead of sitting on a tinted block. build() is bound via lvim-utils.highlight.bind in
-- setup(), so every group re-derives on ColorScheme / palette sync — no lvim-colorscheme
-- dependency (the theming-architecture rule: each plugin self-themes from the palette).
--
---@module "lvim-test.highlights"

local M = {}

--- Build the group table from a palette (passed by highlight.bind; falls back to a require so it
--- also works when called directly).
---@param c? table  the live palette
---@return table<string, table>
function M.build(c)
    c = c or require("lvim-utils.colors")

    return {
        -- Status foregrounds (tree rows, eol status, statusline segment).
        LvimTestPassed = { fg = c.green },
        LvimTestFailed = { fg = c.red },
        LvimTestRunning = { fg = c.yellow },
        LvimTestSkipped = { fg = c.blue },

        -- Gutter status signs — accent FG only (no bg) so the dot blends into the buffer background.
        LvimTestPassedSign = { fg = c.green },
        LvimTestFailedSign = { fg = c.red },
        LvimTestRunningSign = { fg = c.yellow },
        LvimTestSkippedSign = { fg = c.blue },

        -- Summary-tree structure — the lvim-db drawer look: bold coloured "header" nodes
        -- (file/dir/namespace), plainer coloured leaves (tests), yellow fold carets.
        LvimTestFile = { fg = c.cyan, bold = true }, -- a test file (a bold header, like a db table)
        LvimTestDir = { fg = c.blue, bold = true },
        LvimTestNamespace = { fg = c.purple, bold = true }, -- the `{}` group / describe row
        LvimTestName = { fg = c.orange }, -- an as-yet-unrun test's tube icon + name (coloured, not grey)
        LvimTestChevron = { fg = c.yellow }, -- the tree fold arrows (▸/▾)
        LvimTestAdapter = { fg = c.purple, bold = true },
        LvimTestMarked = { fg = c.blue, bold = true },
        LvimTestWatching = { fg = c.yellow },

        -- Dim detail (eol short message / aggregate counts).
        LvimTestDetail = { fg = c.comment },
    }
end

return M
