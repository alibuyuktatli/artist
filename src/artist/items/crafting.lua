local gui = require "artist.gui.core"
local keybinding = require "metis.input.keybinding"
local log = require("artist.lib.log").get_logger("artist.items.crafting")

local M = {}

local function read_craft()
  local h = fs.open(".artist.d/src/craft.json", "r")
  if not h then return {} end
  local content = h.readAll()
  h.close()
  local ok, tbl = pcall(textutils.unserializeJSON, content)
  if ok and type(tbl) == "table" then return tbl end
  return {}
end

local function write_craft(tbl)
  local h = fs.open(".artist.d/src/craft.json", "w")
  if not h then return end
  h.write(textutils.serializeJSON(tbl))
  h.close()
end

function M.delete_recipe(hash)
  if type(hash) ~= "string" or hash == "" then return false end

  local craft = read_craft()
  if not craft[hash] then return false end

  craft[hash] = nil
  write_craft(craft)
  return true
end

function M.show(context, ui, width, height)
  local dwidth, dheight = math.min(width - 2, 60), 14
  local x, y = math.floor((width - dwidth) / 2) + 1, math.floor((height - dheight) / 2) + 1

  local function pop_and_end()
    context.mediator:publish("craft_teach.end")
    ui:pop()
  end

  local function save()
    if not turtle then pop_and_end() return end

    local pattern = {}
    for i = 1, 16 do
      local info = turtle.getItemDetail(i, true)
      if info then pattern[#pattern + 1] = { display_name = info.displayName or info.name, name = info.name, slot = i } end
    end

    if turtle.craft then pcall(turtle.craft) end
    sleep(0.2)

    local produced = turtle.getItemDetail(1, true)
    local entry = { pattern = pattern }
    if produced then
      entry.display_name = produced.displayName or produced.name
      entry.count = produced.count or 1

      local existing = read_craft() or {}
      local key = produced.name
      existing[key] = entry
      write_craft(existing)
    end

    pop_and_end()
  end

  context.mediator:publish("craft_teach.start")

  if not turtle then
    ui:push(gui.Frame {
      x = x, y = y, width = dwidth, height = 6,
      keymap = keybinding.create_keymap { ["C-d"] = pop_and_end },
      children = {
        gui.Text { x = x + 1, y = y + 1, width = dwidth - 2, text = "Teach crafting recipe" },
        gui.Text { x = x + 1, y = y + 2, width = dwidth - 2, text = "No turtle attached — teaching requires a turtle." },
        gui.Button { x = x + 1, y = y + 4, text = "Close", bg = "red", run = pop_and_end },
      },
    })
    return
  end

  local children = { gui.Text { x = x + 1, y = y + 0, width = dwidth - 2, text = "Teach crafting recipe (detected pattern)" } }

  children[#children + 1] = gui.Text { x = x + 1, y = y + 4, width = dwidth - 2, text = "Press OK to craft and save this recipe." }
  children[#children + 1] = gui.Button { x = x + 1, y = y + 8, text = "OK", bg = "green", run = save }
  children[#children + 1] = gui.Button { x = x + dwidth - 9, y = y + 8, text = "Cancel", bg = "red", run = pop_and_end }

  ui:push(gui.Frame { x = x, y = y + 2, width = dwidth, height = 10, keymap = keybinding.create_keymap { ["enter"] = save, ["C-d"] = pop_and_end }, children = children })
end

function M.open_dialog(context, ui, width, height, item)
  if not item then return end
  local dwidth, dheight = math.min(width - 2, 30), 8
  local x, y = math.floor((width - dwidth) / 2) + 1, math.floor((height - dheight) / 2) + 1

  local count_input = require("artist.gui.extra").NumberInput { x = x + 1, y = y + 2, width = dwidth - 2, placeholder = "Count", default = 1 }

  local function do_craft()
    if count_input.value then
      context.mediator:publish("craft.request", { hash = item.hash, quantity = count_input.value })
    end
    ui:pop()
  end

  ui:push(require("artist.gui.core").Frame {
    x = x, y = y, width = dwidth, height = dheight,
    keymap = require("metis.input.keybinding").create_keymap { ["enter"] = do_craft, ["C-d"] = function() ui:pop() end },
    children = {
      require("artist.gui.core").Text { x = x + 1, y = y + 1, width = dwidth - 2, text = "Craft: " .. (item.displayName or item.hash) },
      count_input,
      require("artist.gui.core").Button { x = x + 1, y = y + dheight - 2, text = "Craft", bg = "green", run = do_craft },
      require("artist.gui.core").Button { x = x + dwidth - 9, y = y + dheight - 2, text = "Cancel", bg = "red", run = function() ui:pop() end },
    },
  })
end

function M.init(context)
  -- Autonomous crafting queue. Listens for craft.request events and processes
  -- them sequentially. Uses the items API to pull ingredients into the turtle
  -- inventory, calls turtle.craft(), then pushes the result back into the system.
  local Items = context:require("artist.core.items")
  local turtle_helpers = require "artist.lib.turtle"

  local queue = {}
  local processing = false

  local extract_id = 0
  local function extract_to_turtle(hash, count, slot)
    extract_id = extract_id + 1
    local id = extract_id
    local extracted = 0
    log("extract_to_turtle: requesting %d x %s -> slot %s (id=%d)", count, tostring(hash), tostring(slot), id)
    Items:extract(turtle_helpers.get_name(), hash, count, slot, function(n)
      extracted = n
      log("extract_to_turtle: callback id=%d got=%d", id, n)
      os.queueEvent("craft_extract_done", id)
    end)

    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "craft_extract_done" and ev[2] == id then break end
    end

    log("extract_to_turtle: finished id=%d extracted=%d", id, extracted)
    return extracted
  end

  local function return_from_turtle(slot, count)
    -- Move items from turtle slot back into the system
    log("return_from_turtle: returning %s items from turtle slot %s", tostring(count), tostring(slot))
    Items:insert(turtle_helpers.get_name(), slot, count)
  end

  local function process_request(req, depth, stack)
    depth = depth or 0
    stack = stack or {}

    local function flush_turtle()
      if not turtle then return end
      for i = 1, 16 do
        local item = turtle.getItemDetail(i, true)
        if item then
          log("flush_turtle: moving slot %d => %s x%d", i, tostring(item.name), item.count or 0)
          Items:insert(turtle_helpers.get_name(), i, item)
        end
      end
    end

    local function finish_and_flush(ok, msg)
      context.mediator:publish("craft.finished", req)
      if msg then log("process_request: finishing: %s", tostring(msg)) end
      flush_turtle()
      if req and req.hash then stack[req.hash] = nil end
      return ok
    end

    if depth > 6 then
      log("process_request: recursion depth exceeded for %s", tostring(req and req.hash))
      context.mediator:publish("craft.error", { request = req, error = "Recursion depth exceeded" })
      return finish_and_flush(false, "recursion depth exceeded")
    end

    log("process_request: start req=%s depth=%d", textutils.serialize(req or {}), depth)
    -- Notify system that crafting for this request is starting
    context.mediator:publish("craft.started", req)
    if req and stack[req.hash] then
      local function stack_list(s)
        local keys = {}
        for k, _ in pairs(s) do table.insert(keys, tostring(k)) end
        return table.concat(keys, ",")
      end
      log("process_request: cycle detected for %s (stack=%s)", tostring(req.hash), stack_list(stack))
      context.mediator:publish("craft.error", { request = req, error = "Craft cycle detected: " .. tostring(req.hash) .. " stack=" .. stack_list(stack) })
      return finish_and_flush(false, "cycle detected: " .. tostring(req.hash))
    end
    if req and req.hash then stack[req.hash] = true end

    local recipe_tbl = read_craft()
    local recipe = (req and req.hash) and recipe_tbl[req.hash]
    if not recipe then
      local msg = "No recipe for " .. tostring(req and req.hash)
      log("process_request: %s", msg)
      context.mediator:publish("craft.error", { request = req, error = msg })
      if req and req.hash then stack[req.hash] = nil end
      return finish_and_flush(false, "no recipe")
    end

    -- Interpret `req.quantity` as the desired number of items to receive, not
    -- the number of craft operations. Compute how many operations are required
    -- based on the recipe's produced count.
    local desired_items = (req and req.quantity) or 1
    local per_craft = recipe.count or 1
    local ops = math.floor((desired_items + per_craft - 1) / per_craft)
    log("process_request: desired_items=%d per_craft=%d => ops=%d for %s", desired_items, per_craft, ops, tostring(req.hash))

    local function get_stack_limit(hash, fallback)
      local entry = Items:get_item(hash)
      local max_count = entry and entry.details and entry.details.maxCount
      if type(max_count) == "number" and max_count > 0 then return max_count end
      return fallback or 64
    end

    local needed_per_op = {}
    for _, p in ipairs(recipe.pattern or {}) do
      needed_per_op[p.name] = (needed_per_op[p.name] or 0) + 1
    end
    -- Planning pass: simulate the full craft tree before starting extraction.
    -- We consume a virtual stock snapshot, compute all raw missing items and
    -- how many dependency craft operations are required.
    local function simulate_requirements(hash, desired, sim, depth, visiting)
      if desired <= 0 then return true end
      depth = depth or 0
      visiting = visiting or {}
      if depth > 12 then
        return false, "simulation depth exceeded at " .. tostring(hash)
      end

      if sim.stock[hash] == nil then
        local entry = Items:get_item(hash)
        sim.stock[hash] = (entry and entry.count) or 0
      end

      local available = sim.stock[hash]
      if available >= desired then
        sim.stock[hash] = available - desired
        return true
      end

      local remaining = desired - available
      sim.stock[hash] = 0

      local recipes = read_craft()
      local dep_recipe = recipes[hash]
      if not dep_recipe or visiting[hash] then
        if visiting[hash] then
          log("simulate_requirements: cycle hit at %s, treating remaining as raw", tostring(hash))
        end
        sim.raw_missing[hash] = (sim.raw_missing[hash] or 0) + remaining
        return true
      end

      visiting[hash] = true
      local dep_per_craft = dep_recipe.count or 1
      local dep_ops = math.floor((remaining + dep_per_craft - 1) / dep_per_craft)
      sim.craft_ops[hash] = (sim.craft_ops[hash] or 0) + dep_ops

      local per_op = {}
      for _, p in ipairs(dep_recipe.pattern or {}) do
        per_op[p.name] = (per_op[p.name] or 0) + 1
      end

      for name, cnt in pairs(per_op) do
        local ok, err = simulate_requirements(name, cnt * dep_ops, sim, depth + 1, visiting)
        if not ok then
          visiting[hash] = nil
          return false, err
        end
      end

      visiting[hash] = nil
      sim.stock[hash] = (sim.stock[hash] or 0) + (dep_ops * dep_per_craft)

      local final_available = sim.stock[hash]
      if final_available >= remaining then
        sim.stock[hash] = final_available - remaining
      else
        local raw_left = remaining - final_available
        sim.stock[hash] = 0
        sim.raw_missing[hash] = (sim.raw_missing[hash] or 0) + raw_left
      end

      return true
    end

    local plan = { stock = {}, raw_missing = {}, craft_ops = {} }
    do
      local ok = true
      local err = nil
      for name, cnt in pairs(needed_per_op) do
        ok, err = simulate_requirements(name, cnt * ops, plan, 0, {})
        if not ok then break end
      end

      if not ok then
        log("process_request: planning failed: %s", tostring(err))
        context.mediator:publish("craft.error", { request = req, error = "Planning failed: " .. tostring(err) })
        if req and req.hash then stack[req.hash] = nil end
        return finish_and_flush(false, "planning failed")
      end
    end

    log("process_request: planning raw_missing=%s", textutils.serialize(plan.raw_missing))
    log("process_request: planning craft_ops=%s", textutils.serialize(plan.craft_ops))

    if next(plan.raw_missing) then
      context.mediator:publish("craft.error", { request = req, error = "Missing raw materials", missing = plan.raw_missing })
      if req and req.hash then stack[req.hash] = nil end
      return finish_and_flush(false, "missing raw material")
    end

    -- Craft all planned dependencies before root craft begins.
    for name, dep_ops in pairs(plan.craft_ops) do
      if name ~= req.hash and dep_ops > 0 then
        local dep_recipe = read_craft()[name]
        local dep_qty = dep_ops * ((dep_recipe and dep_recipe.count) or 1)
        log("process_request: pre-crafting planned dependency %s qty=%d (ops=%d)", tostring(name), dep_qty, dep_ops)
        local ok = process_request({ hash = name, quantity = dep_qty }, depth + 1, stack)
        if not ok then
          log("process_request: failed planned dependency %s", tostring(name))
          if req and req.hash then stack[req.hash] = nil end
          return finish_and_flush(false, "failed planned dependency")
        end
      end
    end
    local remaining_ops = ops
    local batch_no = 0
    while remaining_ops > 0 do
      batch_no = batch_no + 1

      local output_stack_limit = get_stack_limit(req.hash, 64)
      local max_batch_ops = math.max(1, math.floor(output_stack_limit / math.max(per_craft, 1)))

      -- Keep ingredient slots within per-slot stack limits too.
      for _, p in ipairs(recipe.pattern or {}) do
        local ingredient_stack_limit = get_stack_limit(p.name, 64)
        if ingredient_stack_limit < max_batch_ops then
          max_batch_ops = ingredient_stack_limit
        end
      end
      if max_batch_ops < 1 then max_batch_ops = 1 end

      local batch_ops = math.min(remaining_ops, max_batch_ops)
      log("process_request: batch %d (ops=%d, remaining_before=%d, output_stack=%d)", batch_no, batch_ops, remaining_ops, output_stack_limit)

      -- Ensure ingredients are available
      local needed = {}
      for name, cnt in pairs(needed_per_op) do
        needed[name] = cnt * batch_ops
      end

      -- Check materials availability for this batch.
      local missing = {}
      local have_all = true
      for name, cnt in pairs(needed) do
        local entry = Items:get_item(name)
        local have = (entry and entry.count) or 0
        if have < cnt then
          missing[name] = cnt - have
          have_all = false
        end
      end
      if not have_all then
        local msg = "Missing materials during batch execution"
        log("process_request: %s: %s", msg, textutils.serialize(missing))
        context.mediator:publish("craft.error", { request = req, error = msg, missing = missing })
        if req and req.hash then stack[req.hash] = nil end
        return finish_and_flush(false, "missing during batch")
      end
      log("process_request: materials available")

      -- Extract ingredients into turtle
      local extracted_record = {}
      local ok = true
      for _, p in ipairs(recipe.pattern or {}) do
        log("process_request: extracting ingredient %s x%d -> slot %d", tostring(p.name), batch_ops, p.slot)
        local got = extract_to_turtle(p.name, batch_ops, p.slot)
        log("process_request: extracted %d of %s to slot %d", got, tostring(p.name), p.slot)
        table.insert(extracted_record, { slot = p.slot, got = got })
        if got < batch_ops then ok = false; break end
      end

      if not ok then
        log("process_request: extraction failed, returning extracted items")
        -- Return any extracted items back to system
        for _, rec in ipairs(extracted_record) do
          if rec.got and rec.got > 0 then
            log("process_request: returning %d from slot %d", rec.got, rec.slot)
            return_from_turtle(rec.slot, rec.got)
          end
        end
        -- Wait for items change before retrying
        log("process_request: waiting for items.change before retry")
        os.pullEvent("items.change")
      else
        -- Perform crafting
        log("process_request: invoking turtle.craft(%d)", batch_ops)
        local crafted_ok = true
        if turtle and turtle.craft then
          local call_ok, result = pcall(turtle.craft, batch_ops)
          crafted_ok = call_ok and result
        end
        if not crafted_ok then
          local msg = "turtle.craft failed for batch"
          log("process_request: %s", msg)
          context.mediator:publish("craft.error", { request = req, error = msg })
          return finish_and_flush(false, msg)
        end
        sleep(0.2)

        -- Move produced item (slot 1) into system
        local produced = turtle.getItemDetail(1)
        log("process_request: turtle produced => %s", textutils.serialize(produced or {}))
        local move_count = (produced and produced.count) or (batch_ops * per_craft)
        if move_count > 0 then
          log("process_request: moving %d produced items into system", move_count)
          Items:insert(turtle_helpers.get_name(), 1, move_count)
          sleep(0.2)
        end

        remaining_ops = remaining_ops - batch_ops
        log("process_request: batch complete, remaining_ops=%d", remaining_ops)
      end
    end
    log("process_request: finished req=%s", tostring(req and req.hash))
    -- Notify system that crafting for this request is finished
    return finish_and_flush(true)
  end

  -- Queue processor: subscribe to mediator events
  context.mediator:subscribe("craft.request", function(req)
    if req then table.insert(queue, req) end

    if not processing then
      processing = true
      context:spawn(function()
        while #queue > 0 do
          local r = table.remove(queue, 1)
          local ok, res_or_err = pcall(process_request, r, 0, {})
          if not ok then
            context.mediator:publish("craft.error", { request = r, error = tostring(res_or_err) })
          else
            if not res_or_err then
              context.mediator:publish("craft.error", { request = r, error = "Craft failed" })
            end
          end
        end
        processing = false
      end)
    end
  end)
end

return M
