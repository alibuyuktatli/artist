local gui = require "artist.gui.core"
local extra = require "artist.gui.extra"
local ItemList = require "artist.gui.item_list"
local keybinding = require "metis.input.keybinding"
local log = require("artist.lib.log").get_logger("artist.craft")
local schema = require "artist.lib.config".schema

return function(context, extract_items)
    local config = context.config
    :group("turtle_craft", "Options related to the turtle craft")
    :define("turtle_peripheral_name", "Turtle peripheral name required for craft to work", "turtle_0", schema.string)
    :get()
  local width, height = term.getSize()

  local ui = gui.UI(term.current())
  local function pop_frame() ui:pop() end

  local function craft_item_flow(item, craft_amount, on_done)
    local item_name = item.hash
    local craftlist_path = ".artist.d/craftlist.json"
    local items = context:require("artist.core.items")
    local turtle_name = config.turtle_peripheral_name
    local craftlist = {}
    if fs.exists(craftlist_path) then
      local h = fs.open(craftlist_path, "r")
      local content = h.readAll()
      h.close()
      craftlist = textutils.unserialiseJSON(content) or {}
    end
    item.display_name = craftlist[item_name].display_name

    -- 1. Gerekli tüm malzemeleri ve craft adımlarını hesapla
    local function calculate_craft_requirements(target, amount)
      local required_items = {}
      local craft_steps = {}

      local function add_required(name, amt, display_name)
        if not required_items[name] then
          required_items[name] = {amt = 0, display_name = display_name}
        end
        required_items[name].amt = required_items[name].amt + amt
      end

      local function resolve(name, amt, display_name)
        local entry = items:get_item(name)
        local inv_count = entry and entry.count or 0
        if inv_count >= amt then
          add_required(name, amt, display_name)
          return
        end

        local craft = craftlist[name]
        if craft and craft.pattern then
          local output_count = craft.count or 1
          local to_craft = math.ceil((amt - inv_count) / output_count)
          table.insert(craft_steps, { name = name, amount = to_craft })

          -- Alt malzemeleri craft.pattern'deki miktarları toplayarak hesapla
          local sub_needed = {}
          for _, sub in ipairs(craft.pattern) do
            local existing = sub_needed[sub.name]
            sub_needed[sub.name] = {count = (existing and existing.count or 0) + 1, display_name = sub.display_name}
          end
          for sub_name, sub_value in pairs(sub_needed) do
            -- Her craft işlemi için sub_count kadar gerekiyor, toplamda to_craft * sub_count kadar lazım
            resolve(sub_name, to_craft * sub_value.count, sub_value.display_name)
          end

          -- Envanterde varsa kalan miktarı ekle
          if inv_count > 0 then add_required(name, inv_count, display_name) end
        else
          -- Craftlanamayan base item
          add_required(name, amt, display_name)
        end
      end

      resolve(target, amount, item.display_name)

      -- craft_steps tablosunu terse çevir
      local reversed_steps = {}
      for i = #craft_steps, 1, -1 do
        table.insert(reversed_steps, craft_steps[i])
      end

      -- for k,v in pairs(reversed_steps) do
      --   log(string.format('_ %s %s',v.name, v.amount))
      -- end
      return required_items, reversed_steps
    end

    -- Örnek kullanım:
    local required_items, craft_steps = calculate_craft_requirements(item_name, craft_amount)

    -- 2. Gerekli itemlar sistemde var mı kontrol et, eksikleri topla
    local missing = {}
    for req_name, req_value in pairs(required_items) do
      local entry = items:get_item(req_name)
      local inv_count = entry and entry.count or 0
      if inv_count < req_value.amt then
        missing[req_name] = {count = req_value.amt - inv_count, display_name = req_value.display_name}
      end
    end

    -- 3. Eksik varsa ekrana ve varsa printer'a yazdır, craftı bitir
    if next(missing) then
      local msg = "Eksik Esyalar:\n"
      for k, v in pairs(missing) do
        msg = msg .. ("- %s: %d\n"):format(v.display_name, v.count)
      end

      -- GUI'ye yaz
      if on_done then
        on_done(false, msg)
      end

      -- Printer'a yaz
      -- if peripheral.find then
      --   local printer = peripheral.find("printer")
      --   if printer then
      --     printer.newPage()
      --     printer.setPageTitle("Eksik Craft Malzemeleri")
      --     printer.write("Gerekenler:\n")
      --     for k, v in pairs(required_items) do
      --       printer.write(("- %s: %d\n"):format(k, v))
      --     end
      --     printer.write("\nEksik:\n")
      --     for k, v in pairs(missing) do
      --       printer.write(("- %s: %d\n"):format(k, v))
      --     end
      --     printer.endPage()
      --   end
      -- end
      return
    end

    for _, step in ipairs(craft_steps) do
      local turtle_module = context:require("artist.gui.interface.turtle")
      if turtle_module and turtle_module.set_dropoff_craft_disable then
        turtle_module.set_dropoff_craft_disable(true)
      end
      local craft = craftlist[step.name]
      if craft and craft.pattern then
        for _, sub in ipairs(craft.pattern) do
          items:extract(turtle_name, sub.name, step.amount, sub.slot)
        end
        for i = 1, step.amount do
          turtle.craft()
          -- Envanterin boşalmasını bekle
          if turtle_module and turtle_module.set_dropoff_craft_disable then
            turtle_module.set_dropoff_craft_disable(false)
          end
          while true do
            local empty = true
            for slot = 1, 16 do
              if turtle.getItemCount(slot) > 0 then
                empty = false
                break
              end
            end
            if empty then break end
            sleep(0.2)
          end
        end
      end
    end

    if on_done then
      on_done(true)
    end
  end

  local function show_craft_input(item)
    local width, height = term.getSize()
    local dwidth, dheight = math.min(width - 2, 30), 8
    local x, y = math.floor((width - dwidth) / 2) + 1, math.floor((height - dheight) / 2) + 1

    local input = extra.NumberInput {
      x = x + 2, y = y + 2, width = dwidth - 4, placeholder = "Adet", default = 1,
    }

    local function do_craft()
      if not input.value or input.value < 1 then return end
      craft_item_flow(item, input.value, function(success, err)
        local msg = success and ("Craftlandi.") or (err or "")
        local msg_width = #msg + 4
        local msg_x = math.floor((width - msg_width) / 2) + 1
        local msg_y = math.floor(height / 2)
        term.setCursorPos(1, 1)
        term.setBackgroundColour(colours.red)
        term.setTextColour(colours.white)
        print(msg)
        if success then
          sleep(.5)
        else
          os.pullEvent("key")
        end
        ui:pop()
      end)
    end

    ui:push(gui.Frame {
      x = x, y = y, width = dwidth, height = dheight,
      keymap = keybinding.create_keymap { ["enter"] = do_craft, ["C-d"] = pop_frame },
      children = {
        gui.Text { x = x + 2, y = y + 1, width = dwidth - 4, text = "Kac tane craftlansin?" },
        input,
        gui.Button { x = x + 2, y = y + dheight - 2, text = "Craftla", bg = "green", run = do_craft },
        gui.Button { x = x + dwidth - 10, y = y + dheight - 2, text = "Iptal", bg = "red", run = pop_frame },
      },
    })
  end

  local item_list = ItemList {
    y = 2, height = height - 1,
    selected = function(item)
      if item.craft then
        show_craft_input(item)
      else
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
      end
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

  local function push_craft_pattern()
    local width, height = term.getSize()
    local dwidth, dheight = math.min(width - 2, 40), 10
    local x, y = math.floor((width - dwidth) / 2) + 1, math.floor((height - dheight) / 2) + 1

    local gui = require "artist.gui.core"
    local keybinding = require "metis.input.keybinding"
    local turtle_helpers = require "artist.lib.turtle"
    local json = textutils
    local craftlist_path = ".artist.d/craftlist.json"
    local turtle_name = turtle_helpers.get_name()
    local items = context:require("artist.core.items")
    local turtle_module = context:require("artist.gui.interface.turtle")

    if turtle_module and turtle_module.set_dropoff_craft_disable then
      turtle_module.set_dropoff_craft_disable(true)
    end

    local info_text = "Craft patternini yapınız..\nKaydet'e basınca pattern kaydedilecek."
    local info_lines = {}
    for line in info_text:gmatch("[^\n]+") do table.insert(info_lines, line) end

    local function save_pattern()
      local pattern = {}
      for i = 1, 16 do
        local detail = turtle.getItemDetail(i, true)
        if detail then
          if context.config.data.hashing.enable then
            if detail.nbt then
              detail.name = detail.name .. "@" .. detail.nbt
            end
          end
        end
          pattern[i] = { slot = i, name = detail.name, displayName = detail.displayName }
        else
          pattern[i] = nil
        end
      end

      -- Turtle'da craft işlemi yap
      turtle.craft()
      local crafted = turtle.getItemDetail(1, true)
      if not crafted then
        if turtle_module and turtle_module.set_dropoff_craft_disable then   
          turtle_module.set_dropoff_craft_disable(false)
        end
        ui:pop()
        return
      end
      local crafted_name = crafted.name
      local crafted_display_name = crafted.displayName

      -- craftlist.json'u oku veya oluştur
      local craftlist = {}
      if fs.exists(craftlist_path) then
        local h = fs.open(craftlist_path, "r")
        local content = h.readAll()
        h.close()
        craftlist = textutils.unserialiseJSON(content) or {}
      end

      -- patterni craftlist'e ekle (crafted_name anahtarına)
      craftlist[crafted_name] = {
        count = crafted.count,
        display_name = crafted_display_name,
        pattern = {},
      }
      for i = 1, 16 do
        if pattern[i] then
          table.insert(craftlist[crafted_name].pattern, { slot = i, name = pattern[i].name, display_name = pattern[i].displayName })
        end
      end

      -- craftlist.json'a yaz
      local h = fs.open(craftlist_path, "w")
      h.write(textutils.serialiseJSON(craftlist))
      h.close()

      -- craft_cache'i tekrar yükle
      if ItemList then
        local item_list_mod = ItemList
        if item_list_mod.load_craftlist_items then
          item_list_mod.load_craftlist_items()
        end
      end

      if turtle_module and turtle_module.set_dropoff_craft_disable then   
        turtle_module.set_dropoff_craft_disable(false)
      end

      ui:pop()
    end

    ui:push(gui.Frame {
      x = x, y = y, width = dwidth, height = dheight,
      keymap = keybinding.create_keymap { ["enter"] = save_pattern, ["C-d"] = pop_frame },
      children = {
        gui.Text { x = x + 1, y = y + 1, width = dwidth - 2, text = info_lines[1] or "" },
        gui.Text { x = x + 1, y = y + 2, width = dwidth - 2, text = info_lines[2] or "" },
        gui.Text { x = x + 1, y = y + 3, width = dwidth - 2, text = info_lines[3] or "" },
        gui.Button { x = x + 1, y = y + dheight - 3, text = "Kaydet", bg = "green", run = save_pattern },
        gui.Button { x = x + dwidth - 9, y = y + dheight - 3, text = "İptal", bg = "red", run = function()
          turtle_module.set_dropoff_craft_disable(false)
          pop_frame()
        end },
      },
    })
  end

  -- When we receive an item difference we update the item list. This schedules
  -- a redraw if required.
  context.mediator:subscribe("item_list.update", function(items) item_list:update_items(items) end)

  context:spawn(function()
    ui:push {
      keymap = keybinding.create_keymap {
        ["C-d"] = function() ui:pop() end,
        ["C-S-f"] = push_furnace,
        ["C-x"] = push_craft_pattern, -- Ctrl+X ile craft pattern gui
        ["C-z"] = function()
          local selected = item_list:get_selected()
          if selected then
            if selected.craft then
              show_craft_input(selected)
            else
              -- Normal eşya ise craftlistte karşılığı var mı bak
              local craftlist_path = ".artist.d/craftlist.json"
              if fs.exists(craftlist_path) then
                local h = fs.open(craftlist_path, "r")
                local content = h.readAll()
                h.close()
                local craftlist = textutils.unserialiseJSON(content) or {}
                if craftlist[selected.hash] then
                  show_craft_input({
                    hash = selected.hash,
                    craft = true,
                    displayName = (craftlist[selected.hash].display_name or selected.displayName)
                  })
                end
              end
            end
          end
        end,
        ["C-n"] = function()
          local selected = item_list:get_selected()
          if selected then
            local craftlist_path = ".artist.d/craftlist.json"
            if fs.exists(craftlist_path) then
              local h = fs.open(craftlist_path, "r")
              local content = h.readAll()
              h.close()
              local craftlist = textutils.unserialiseJSON(content) or {}
              local hash_to_remove = selected.hash
              -- Eğer normal eşya ise craftlistte karşılığı var mı bak
              if not selected.craft and craftlist[selected.hash] then
                hash_to_remove = selected.hash
              elseif selected.craft then
                hash_to_remove = selected.hash
              else
                hash_to_remove = nil
              end
              if hash_to_remove and craftlist[hash_to_remove] then
                craftlist[hash_to_remove] = nil
                local h2 = fs.open(craftlist_path, "w")
                h2.write(textutils.serialiseJSON(craftlist))
                h2.close()
                -- Cache'i yenile
                if ItemList and ItemList.load_craftlist_items then
                  ItemList.load_craftlist_items()
                end
                -- Listeyi güncelle
                item_list:set_filter("")
              end
            end
          end
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
