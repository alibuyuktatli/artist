local gui = require "artist.gui.core"
local extra = require "artist.gui.extra"
local ItemList = require "artist.gui.item_list"
local keybinding = require "metis.input.keybinding"
local crafting = require "artist.items.crafting"

return function(context, extract_items)
  local width, height = term.getSize()

  local ui = gui.UI(term.current())
  local function pop_frame() ui:pop() end
  crafting.init(context)

  local function open_craft_dialog(item)
    if not item then return end
    local dwidth, dheight = math.min(width - 2, 30), 8
    local x, y = math.floor((width - dwidth) / 2) + 1, math.floor((height - dheight) / 2) + 1

    local count_input = extra.NumberInput { x = x + 1, y = y + 2, width = dwidth - 2, placeholder = "Count", default = 1 }

    local function do_craft()
      if count_input.value then
        context.mediator:publish("craft.request", { hash = item.hash, quantity = count_input.value })
      end
      ui:pop()
    end

    ui:push(gui.Frame {
      x = x, y = y, width = dwidth, height = dheight,
      keymap = keybinding.create_keymap { ["enter"] = do_craft, ["C-d"] = pop_frame },
      children = {
        gui.Text { x = x + 1, y = y + 1, width = dwidth - 2, text = "Craft: " .. (item.displayName or item.hash) },
        count_input,
        gui.Button { x = x + 1, y = y + dheight - 2, text = "Craft", bg = "green", run = do_craft },
        gui.Button { x = x + dwidth - 9, y = y + dheight - 2, text = "Cancel", bg = "red", run = pop_frame },
      },
    })
  end

  local item_list = ItemList {
    y = 2, height = height - 1,
    selected = function(item)
      -- If the item is craftable and not present in system, open craft UI
      if item.craft and (not item.count or item.count == 0) then
        crafting.open_dialog(context, ui, width, height, item)
        return
      end
      local dwidth, dheight = math.min(width - 2, 30), 10
      local x, y = math.floor((width - dwidth) / 2) + 1, math.floor((height - dheight) / 2) + 1

      local input = extra.NumberInput {
        x = x, y = y + 2, width = dwidth, placeholder = "64", default = 64,
      }

      local function extract()
        if input.value then extract_items(item.hash, input.value) end
        ui:pop()
      end

      ui:push(gui.Frame {
        x = x, y = y, width = dwidth, height = dheight,
        keymap = keybinding.create_keymap { ["enter"] = extract, ["C-d"] = pop_frame },
        children = {
          gui.Text { x = x + 1, y = y + 1, width = dwidth - 2, text = "Extract: " .. item.displayName },
          input,
          gui.Button { x = x + 1, y = y + 6, text = "Extract", bg = "green", run = extract },
          gui.Button { x = x + dwidth - 9, y = y + 6, text = "Cancel", bg = "red", run = pop_frame },
        },
      })
    end,
  }

  local function push_furnace()
    local item = item_list:get_selected()
    if not item then return end

    local dwidth, dheight = math.min(width - 2, 30), 10
    local x, y = math.floor((width - dwidth) / 2) + 1, math.floor((height - dheight) / 2) + 1

    local count_input = extra.NumberInput {
      x = x, y = y + 2, width = dwidth - 14, placeholder = "Count", default = 64,
    }

    local furnace_input = extra.NumberInput {
      x = x + dwidth - 14, y = y + 2, width = 14, placeholder = "Furnaces", default = false,
    }

    local function smelt()
      if count_input.value and furnace_input.value ~= nil then
        context:require("artist.items.furnaces"):smelt(item.hash, count_input.value, furnace_input.value or nil)
      end
      ui:pop()
    end

    ui:push(gui.Frame {
      x = x, y = y, width = dwidth, height = dheight,
      keymap = keybinding.create_keymap { ["enter"] = smelt, ["C-d"] = pop_frame },
      children = {
        gui.Text { x = x + 1, y = y + 1, width = dwidth - 2, text = "Smelt: " .. item.displayName },
        count_input,
        furnace_input,
        gui.Button { x = x + 1, y = y + 6, text = "Smelt", bg = "green", run = smelt },
        gui.Button { x = x + dwidth - 9, y = y + 6, text = "Cancel", bg = "red", run = pop_frame },
      },
    })
  end

  local function push_teach()
    crafting.show(context, ui, width, height)
  end

  local function push_delete_recipe()
    local item = item_list:get_selected()
    if not item or not item.craft then return end

    local dwidth, dheight = math.min(width - 2, 50), 8
    local x, y = math.floor((width - dwidth) / 2) + 1, math.floor((height - dheight) / 2) + 1

    local function remove_recipe()
      local ok = crafting.delete_recipe(item.hash)
      if ok then
        context.mediator:publish("item_list.update", { [item.hash] = item.count or 0 })
      end
      ui:pop()
    end

    ui:push(gui.Frame {
      x = x, y = y, width = dwidth, height = dheight,
      keymap = keybinding.create_keymap { ["enter"] = remove_recipe, ["C-d"] = pop_frame },
      children = {
        gui.Text { x = x + 1, y = y + 1, width = dwidth - 2, text = "Delete recipe?" },
        gui.Text { x = x + 1, y = y + 2, width = dwidth - 2, text = (item.displayName or item.hash) },
        gui.Button { x = x + 1, y = y + dheight - 2, text = "OK", bg = "green", run = remove_recipe },
        gui.Button { x = x + dwidth - 9, y = y + dheight - 2, text = "Cancel", bg = "red", run = pop_frame },
      },
    })
  end

  -- When we receive an item difference we update the item list. This schedules
  -- a redraw if required.
  context.mediator:subscribe("item_list.update", function(items) item_list:update_items(items) end)

  -- Notification manager: listens for craft errors and displays transient messages
  local notifier = {
    _notes = {},
  }

  function notifier:attach(mark_dirty)
    self.mark_dirty = mark_dirty
    local dur = 5 -- seconds
    context.mediator:subscribe("craft.error", function(info)
      local text = "Craft error"
      if info and info.error then text = text .. ": " .. tostring(info.error) end
      table.insert(self._notes, { text = text, ts = os.clock() })
          if self.mark_dirty then self:mark_dirty() end
    end)

    -- Cleanup expired notes periodically
    context:spawn(function()
      while true do
        local now = os.clock()
        local changed = false
        for i = #notifier._notes, 1, -1 do
          if now - notifier._notes[i].ts > dur then table.remove(notifier._notes, i); changed = true end
        end
        if changed and self._mark_dirty then self._mark_dirty(1) end
        sleep(0.5)
      end
    end)
  end

  function notifier:detach() end

  function notifier:draw(term, palette, masked)
    if #self._notes == 0 then return end
    local width, height = term.getSize()
    local y = height
    for i = #self._notes, 1, -1 do
      local note = self._notes[i]
      local msg = note.text
      term.setBackgroundColour(palette.red)
      term.setTextColour(palette.white)
      term.setCursorPos(1, y)
      local txt = (" " .. msg .. " ")
      if #txt > width then txt = txt:sub(1, width) end
      term.write(txt .. (" "):rep(math.max(0, width - #txt)))
      y = y - 1
      if y < 1 then break end
    end
  end

  function notifier:handle_event() end

  -- Push notifier as a persistent bottom layer so it can draw notifications
  ui:push(notifier)

  -- Show detailed missing-material dialog when a craft error reports missing items
  context.mediator:subscribe("craft.error", function(info)
    if not info or not info.missing then return end
    context:spawn(function()
      local missing = info.missing
      local lines = {}
      for name, cnt in pairs(missing) do
        table.insert(lines, ("%d x %s"):format(cnt, name))
      end

      local dwidth = math.min(width - 4, 50)
      local dheight = math.min(#lines + 4, height - 4)
      local x = math.floor((width - dwidth) / 2) + 1
      local y = math.floor((height - dheight) / 2) + 1

      local children = {
        gui.Text { x = x + 1, y = y + 1, width = dwidth - 2, text = "Missing materials for crafting:" },
      }
      for i = 1, #lines do
        children[#children + 1] = gui.Text { x = x + 1, y = y + 1 + i, width = dwidth - 2, text = lines[i] }
      end

      children[#children + 1] = gui.Button { x = x + 1, y = y + dheight - 2, text = "OK", bg = "green", run = function() ui:pop() end }

      ui:push(gui.Frame { x = x, y = y, width = dwidth, height = dheight, children = children })
    end)
  end)

  context:spawn(function()
    ui:push {
      keymap = keybinding.create_keymap {
        ["C-d"] = function() ui:pop() end,
        ["C-S-f"] = push_furnace,
        ["C-n"] = push_delete_recipe,
        ["C-x"] = push_teach,
        ["C-z"] = function()
          local sel = item_list:get_selected()
          if sel then open_craft_dialog(sel) end
        end,
      },
      children = {
        gui.Input {
          x = 1, y = 1, width = width, fg = "black", bg = "white", placeholder = "Search...",
          changed = function(value) item_list:set_filter(value) end,
        },
        item_list,
      },
    }

    ui:run()

    -- Terrible hack to stop the event loop without showing a stack trace
    error(setmetatable({}, { __tostring = function() return "Interface exited" end }), 0)
  end)
end
