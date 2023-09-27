local tbl = require "artist.lib.tbl"
local log = require "artist.lib.log".get_logger(...)
local schema = require "artist.lib.config".schema

return function(context)
  local _items = context:require("artist.core.items")
  local inventories = context:require("artist.items.inventories")
  local config = context.config
    :group("output", "Automatically pushes items with amount to chest from system.")
    :define("chests", "The chest names available", {}, schema.list(schema.table))
    :define("delay", "The time between output checks.", 5, schema.positive)
    :get()

  for chest in pairs(config.chests) do
    inventories:add_ignored_name(chest)
  end

  context:spawn(function()
    while true do
      for chest, items in pairs(config.chests) do
        local contents = peripheral.call(chest, "list")
        if contents then
          local contentCache = {}
          -- prepare cache for processing
          for slot, item in pairs(contents) do
            -- remove other items than filter
            if items[item.name] == nil then
              _items:insert(chest, slot, 64)
            end

            if contentCache[item.name] then
              contentCache[item.name] = contentCache[item.name] + item.count
            else
              contentCache[item.name] = item.count
            end
          end

          -- process
          for item, itemCount in pairs(items) do
            if contentCache[item] then
              if contentCache[item] < itemCount then
                local req = itemCount - contentCache[item]
                -- log(string.format('item push to %s item %s quantity %s', chest, item, req))
                _items:extract(chest, item, req)
              elseif contentCache[item] > itemCount then
                local totalRemove = contentCache[item] - itemCount
                while totalRemove > 0 do
                  for cSlot, cItem in pairs(contents) do
                    if item == cItem.name then
                      if cItem.count - totalRemove > 0 then
                        _items:insert(chest, cSlot, totalRemove)
                        totalRemove = 0
                      elseif cItem.count - totalRemove < 0 then
                        _items:insert(chest, cSlot, cItem.count)
                        totalRemove = totalRemove - cItem.count
                      end
                    end
                  end
                end
              end
            else
              _items:extract(chest, item, itemCount)
            end
          end
        end
      end
      sleep(5)
    end
  end)
end