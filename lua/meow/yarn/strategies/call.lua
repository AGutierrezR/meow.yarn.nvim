-- MIT License
--
-- Copyright (c) 2025 Andrew Vasilyev <me@retran.me>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- @file: lua/meow/yarn/strategies/call.lua
-- @brief: Strategy for handling LSP call hierarchies
-- @author: Andrew Vasilyev
-- @license: MIT

---@mod meow.yarn.strategies.call
---@brief Strategy for handling LSP call hierarchies.

local get_config = function() return require("meow.yarn.config.internal").get() end
local state = require("meow.yarn.state")
local util = require("meow.yarn.util")

local call_hierarchy_strategy = {
    name = "Call Hierarchy",
    lsp_capability = "callHierarchyProvider",
    lsp_methods = {
        prepare = "textDocument/prepareCallHierarchy",
        get_children = {
            callers = "callHierarchy/incomingCalls",
            callees = "callHierarchy/outgoingCalls",
        },
    },
    directions = {
        callers = { display_name = "Callers" },
        callees = { display_name = "Callees" },
    },
}

-- Routing `data` handed out by prepareCallHierarchy, remembered per client.
-- vtsls strips it from the caller/callee items it returns and then rejects those
-- very items with "Cannot read properties of undefined (reading 'id')", so we
-- replay the last known value. This is required for library declarations
-- (e.g. toFixed in lib.es5.d.ts): their files are not open in the editor, so
-- they cannot be re-prepared and the routing data can only be replayed.
local _routing_data = {}

--- Remembers the routing `data` a server handed out for an item.
---@param client table The LSP client.
---@param item table|nil The prepared LSP item.
local function remember_routing_data(client, item)
    if type(item) == "table" and type(item.data) == "table" then
        _routing_data[client] = item.data
    end
end

--- Returns an item carrying the last routing `data` the client handed out, when
--- the item has none of its own.
---@param client table The LSP client.
---@param item table The LSP item.
---@return table The item, with `data` restored when possible.
local function with_routing_data(client, item)
    if type(item) ~= "table" or type(item.data) == "table" then
        return item
    end
    local data = _routing_data[client]
    if type(data) ~= "table" then
        return item
    end
    return vim.tbl_extend("force", item, { data = data })
end

--- Prepares the root item for a call hierarchy request.
---@param client table The LSP client.
---@param winid number The window ID of the source buffer.
---@param callback function The function to call with the root item.
function call_hierarchy_strategy.prepare_root_item(client, winid, callback)
    winid = winid or 0
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local encoding = util.lsp.get_encoding(client)
    local params = vim.lsp.util.make_position_params(winid, encoding)
    util.lsp.request_async(client, call_hierarchy_strategy.lsp_methods.prepare, params, bufnr, function(items)
        local root_item = (items and items[1]) or nil
        remember_routing_data(client, root_item)
        callback(root_item)
    end)
end

--- Builds a comparable signature out of a list of LSP ranges.
---@param ranges table|nil The ranges to compare.
---@return string|nil The signature, or nil when there is nothing to compare.
local function ranges_signature(ranges)
    if type(ranges) ~= "table" or #ranges == 0 then
        return nil
    end
    local parts = {}
    for _, range in ipairs(ranges) do
        local first, last = range.start, range["end"]
        if not first or not last then
            return nil
        end
        parts[#parts + 1] = string.format("%d:%d-%d:%d", first.line, first.character, last.line, last.character)
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

--- Maps the raw result of an incoming/outgoing calls request to child items.
---@param results table|nil The raw LSP result.
---@param direction_key string The direction the request was made for.
---@return table[] The child LSP items.
local function map_call_results(results, direction_key)
    local children_items = {}
    if type(results) ~= "table" then
        return children_items
    end
    -- A single call site resolves to a single symbol, but some servers (notably
    -- vtsls) return one result per *declaration* of that symbol: e.g. a call to
    -- `str.replace(..)` yields both `replace` (lib.es5.d.ts) and `[Symbol.replace]`
    -- (lib.es2015.symbol.wellknown.d.ts), which TypeScript also names `replace`.
    -- They share the same call site and expand to the same sub-hierarchy, so keep
    -- the first and drop the rest.
    local seen = {}
    for _, result in ipairs(results) do
        if result then
            local child = (direction_key == "callers") and result.from or result.to
            local signature = child and ranges_signature(result.fromRanges) or nil
            local key = signature and string.format("%s#%s#%s", child.name or "", tostring(child.kind or ""), signature)
                or nil
            if child and not (key and seen[key]) then
                if key then
                    seen[key] = true
                end
                -- For incoming calls `fromRanges` are the call sites inside the caller
                -- itself, so they can be used for jumping / previewing. For outgoing
                -- calls they point into the *parent* file, so they are ignored there.
                if direction_key == "callers" and type(result.fromRanges) == "table" and #result.fromRanges > 0 then
                    child = vim.tbl_extend("force", child, { call_site_ranges = result.fromRanges })
                end
                table.insert(children_items, child)
            end
        end
    end
    return children_items
end

--- Re-resolves an item through `textDocument/prepareCallHierarchy` so it carries
--- the routing `data` some servers require on follow-up requests.
--- vtsls (<= 0.3.0) omits `data` on the items it returns inside incoming /
--- outgoing call results, then rejects those very items with
--- "Cannot read properties of undefined (reading 'id')". Re-preparing the item
--- from its position yields an item the server accepts.
---@param client table The LSP client.
---@param item table The item to re-resolve.
---@param callback fun(reprepared: table|nil) Called with the re-prepared item, or nil.
local function reprepare_item(client, item, callback)
    if type(item) ~= "table" then
        return callback(nil)
    end
    if not item.uri or type(item.selectionRange) ~= "table" or not item.selectionRange.start then
        return callback(nil)
    end
    local bufnr = vim.uri_to_bufnr(item.uri)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        pcall(vim.fn.bufload, bufnr)
    end
    local params = {
        textDocument = { uri = item.uri },
        position = item.selectionRange.start,
    }
    util.lsp.request_async(client, call_hierarchy_strategy.lsp_methods.prepare, params, bufnr, function(items)
        local prepared = items and items[1]
        if type(prepared) == "table" and type(prepared.data) == "table" then
            remember_routing_data(client, prepared)
            if item.call_site_ranges then
                prepared = vim.tbl_extend("force", prepared, { call_site_ranges = item.call_site_ranges })
            end
            return callback(prepared)
        end
        callback(nil)
    end)
end

--- Fetches the children of a call hierarchy item.
---@param client table The LSP client.
---@param item table The parent LSP item.
---@param direction_key string The direction to fetch ("callers" or "callees").
---@param callback function The function to call with the child items.
function call_hierarchy_strategy.fetch_children(client, item, direction_key, callback)
    local method = call_hierarchy_strategy.lsp_methods.get_children[direction_key]
    if not method then
        vim.notify("Invalid direction for call hierarchy: " .. direction_key, vim.log.levels.ERROR)
        return callback(nil)
    end
    if type(item) ~= "table" then
        return callback(nil)
    end

    local function send(req_item, on_error)
        req_item = with_routing_data(client, req_item)
        local req_buf = (req_item.uri and vim.uri_to_bufnr(req_item.uri)) or 0
        if req_buf ~= 0 and not vim.api.nvim_buf_is_loaded(req_buf) then
            pcall(vim.fn.bufload, req_buf)
        end
        util.lsp.request_async_raw(client, method, { item = req_item }, req_buf, function(results, err)
            if err then
                return on_error(err)
            end
            callback(map_call_results(results, direction_key))
        end)
    end

    send(item, function(err)
        -- Some servers reject caller/callee items they returned without the
        -- routing `data`. Re-resolve the item via prepareCallHierarchy and
        -- retry once before giving up.
        reprepare_item(client, item, function(prepared)
            if not prepared then
                util.lsp.notify_error(method, err)
                return callback(nil)
            end
            send(prepared, function(retry_err)
                util.lsp.notify_error(method, retry_err)
                callback(nil)
            end)
        end)
    end)
end

--- Generates the help text for the call hierarchy view.
---@param mappings table The user's key mappings.
---@return string The formatted help text.
function call_hierarchy_strategy.generate_help_text(mappings)
    local dir_maps = {}
    -- Use display names from directions
    table.insert(dir_maps, string.format("[%s]%s", mappings.show_super_hierarchy, call_hierarchy_strategy.directions.callers.display_name))
    table.insert(dir_maps, string.format("[%s]%s", mappings.show_sub_hierarchy, call_hierarchy_strategy.directions.callees.display_name))
    local select_hint = ""
    if type(mappings.toggle_select) == "string" and mappings.toggle_select ~= "" then
        select_hint = string.format("[%s]Select | ", mappings.toggle_select)
    end
    return string.format("[%s]Jump | [%s]Toggle | %s%s | [%s]Quit", mappings.jump, mappings.toggle, select_hint,
        table.concat(dir_maps, " | "), mappings.quit)
end

--- Renders a single line in the call hierarchy tree.
---@param node table The NuiTree node to render.
---@param hierarchy_instance table The Hierarchy instance.
---@return table The NuiLine object.
function call_hierarchy_strategy.render_node_line(node, hierarchy_instance)
    local cfg = get_config()
    local Line = require("nui.line")
    local Text = require("nui.text")
    local item = node.lsp_item
    local line = Line()

    line:append(string.rep("  ", math.max(0, node:get_depth() - 1)))

    if node.loading then
        local frame = cfg.icons.animation_frames[state.G.animation_frame_index] or cfg.icons.loading
        line:append(frame .. " ", "SpecialChar")
    elseif node:has_children() or node.has_more then
        line:append(node:is_expanded() and " " or " ", "SpecialChar")
    else
        line:append("  ")
    end

    local lsp_kind_to_name = {
        [6] = "method",
        [12] = "func",
        [13] = "variable",
    }
    local icons = cfg.hierarchies.call_hierarchy.icons
    local kind_name = lsp_kind_to_name[item.kind]
    local icon = item.is_placeholder and cfg.icons.placeholder or (kind_name and icons[kind_name] or icons.default)

    local marker = util.selection_marker(node, hierarchy_instance)

    -- Dim filtered-out nodes; skip custom renderer so the highlight is applied uniformly.
    if node._filtered_out then
        line:append(marker .. icon .. " " .. util.sanitize_text(item.name), "Comment")
        return line
    end

    -- Try user-supplied custom renderer first
    local custom_line = util.try_custom_render(node, item, icon, hierarchy_instance)
    if custom_line then
        return custom_line
    end

    line:append(marker, "Statement")
    line:append(icon .. " ")
    line:append(util.sanitize_text(item.name))

    if item.detail and item.detail ~= "" then
        line:append(" " .. util.sanitize_text(item.detail), "Comment")
    end

    if node:get_depth() == 1 then
        local dir_info = call_hierarchy_strategy.directions[hierarchy_instance.direction_key]
        line:append(string.format(" [%s]", dir_info.display_name), "Comment")
    end

    if item.is_placeholder then return line end

    local call_sites = item.call_site_ranges
    if call_sites and #call_sites > 1 then
        line:append(string.format(" (%d calls)", #call_sites), "Comment")
    end

    local file = item.uri and vim.uri_to_fname(item.uri)
    if file then
        local item_range = util.item_range(item)
        local sel = item_range and item_range.start
        local rhs = ("  %s"):format(util.short_path(file))
        if sel then rhs = rhs .. (":" .. (sel.line + 1)) end
        line:append(" ")
        line:append(Text(rhs, "Comment"))
    end
    return line
end

return call_hierarchy_strategy
