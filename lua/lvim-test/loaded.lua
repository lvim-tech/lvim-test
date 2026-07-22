-- lvim-test.loaded: the loaded-buffer path→bufnr map.
-- The paint consumers (signs, diagnostics) resolve "which buffer holds this test position" for every
-- result on every results event AND on every spinner tick. Doing that with `vim.fn.bufnr(path)`
-- per position is a vimscript-bridge call that scans the buffer list each time — measured ~210 ms for
-- ~500 positions with a few dozen buffers open, which (fired several times a second by the spinners)
-- saturated the main loop and grew with the store as a suite streamed in. Instead build the map ONCE
-- per repaint from the (few) loaded buffers and look each position up in O(1).
--
---@module "lvim-test.loaded"

local M = {}

--- Normalized-path → bufnr for every LOADED, named buffer (unloaded buffers can carry no signs).
--- Keys are `vim.fs.normalize`d so a position path matches regardless of `//` / `..` / trailing
--- differences; callers normalize the position path the same way before looking up.
---@return table<string, integer>
function M.map()
    local out = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                out[vim.fs.normalize(name)] = buf
            end
        end
    end
    return out
end

return M
