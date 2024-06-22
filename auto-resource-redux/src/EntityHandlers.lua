local EntityHandlers = {}

-- seconds to attempt to keep assemblers fed for
local TARGET_INGREDIENT_CRAFT_TIME = 10

local EntityCondition = require "src.EntityCondition"
local EntityCustomData = require "src.EntityCustomData"
local FurnaceRecipeManager = require "src.FurnaceRecipeManager"
local ItemPriorityManager = require "src.ItemPriorityManager"
local LogisticManager = require "src.LogisticManager"
local Storage = require "src.Storage"
local FluidBoxScan = require "src.FluidBoxScan"
local Util = require "src.Util"
local Destroyer = require "src.Destroyer"

-- FIXME: these should be global and/or configurable
local service_period_max = 10 * 60
local service_period_min = 60

local function store_fluids(storage, entity, prod_type_pattern, ignore_limit)
  local remaining_fluids = {}
  local inserted = false
  prod_type_pattern = prod_type_pattern or "^"
  for i, fluid in Util.iter_fluidboxes(entity, prod_type_pattern, false) do
    local new_fluid, amount_added = Storage.add_fluid(storage, fluid, ignore_limit)
    local fluid_key = Storage.get_fluid_storage_key(fluid.name)
    if amount_added > 0 then
      entity.fluidbox[i] = new_fluid.amount > 0 and new_fluid or nil
      inserted = true
    end
    if new_fluid.amount > 0 then
      remaining_fluids[fluid_key] = new_fluid.amount
    end
  end
  return remaining_fluids, inserted
end

function EntityHandlers.store_all_fluids(entity)
  return store_fluids(Storage.get_storage(entity), entity, "^", true)
end

--- Inserts fluids into the given entity
---@param o table
---@param target_fluids table
---@return boolean inserted True if some fluids were inserted
local function insert_fluids(o, target_fluids)
  local inserted = false
  local fluidboxes = o.entity.fluidbox
  for i, fluid, filter, proto in Util.iter_fluidboxes(o.entity, "^", true) do
    if not filter or proto.production_type == "output" then
      goto continue
    end
    fluid = fluid or { name = filter.name, amount = 0 }
    local target = target_fluids[filter.name]
    if not target or target.amount <= 0 then
      goto continue
    end
    local amount_can_insert = Util.clamp(target.amount - fluid.amount, 0, fluidboxes.get_capacity(i))
    local amount_removed, new_temperature = Storage.remove_fluid_in_temperature_range(
      o.storage,
      Storage.get_fluid_storage_key(filter.name),
      target.min_temp or filter.minimum_temperature,
      target.max_temp or filter.maximum_temperature,
      amount_can_insert,
      o.use_reserved
    )
    inserted = true
    fluid.temperature = Util.weighted_average(fluid.temperature, fluid.amount, new_temperature, amount_removed)
    fluid.amount = fluid.amount + amount_removed
    fluidboxes[i] = fluid.amount > 0 and fluid or nil
    ::continue::
  end
  return inserted
end

--- Inserts items into a stack based on the provided priority set
---@param o table
---@param priority_set_key string
---@param stack LuaItemStack
---@param filter_name string|nil The name of the filtered item, if applicable
---@param default_use_reserved boolean If true, the entity will automatically be prioritised if use_reserved is nil
---@return boolean inserted
local function insert_using_priority_set(
  o, priority_set_key,
  stack, filter_name,
  default_use_reserved
)
  local priority_sets = ItemPriorityManager.get_priority_sets(o.entity)
  if not priority_sets[priority_set_key] then
    log(("FIXME: missing priority set \"%s\" for %s!"):format(priority_set_key, o.entity.name))
    return false
  end
  local usable_items = ItemPriorityManager.get_ordered_items(priority_sets, priority_set_key)
  if filter_name then
    usable_items = { [filter_name] = usable_items[filter_name] }
  end
  if table_size(usable_items) == 0 then
    return false
  end

  local current_count = stack.count
  local current_item = current_count > 0 and stack.name or nil
  local expected_count = usable_items[current_item] or 0
  -- set satisfaction to 0 if the item is unknown so that it immediately gets "upgraded" to a better item
  local current_satisfaction = (expected_count > 0) and math.min(1, current_count / expected_count) or 0

  local use_reserved = o.use_reserved
  if use_reserved == nil then
    use_reserved = (default_use_reserved == true)
    EntityCustomData.set_use_reserved(o.entity, use_reserved)
  end

  -- insert first usable item
  for item_name, wanted_amount in pairs(usable_items) do
    if wanted_amount <= 0 then
      goto continue
    end
    local available_amount = Storage.get_available_item_count(
      o.storage,
      item_name, wanted_amount,
      use_reserved
    )
    if available_amount > 0 then
      if item_name == current_item then
        available_amount = available_amount + current_count
      end
      local new_satisfaction = math.min(1, available_amount / wanted_amount)

      if new_satisfaction >= current_satisfaction then
        local amount_added = Storage.add_to_or_replace_stack(
          o.storage, item_name,
          stack, wanted_amount,
          true, use_reserved
        )
        return amount_added > 0
      end
    end
    if item_name == current_item then
      -- avoid downgrading
      break
    end
    ::continue::
  end
  return false
end

--- Inserts fuel into the first slot of an entity's fuel inventory using its priority set
---@param o table
---@param default_use_reserved boolean
---@reutrn number of ticks until the next refuel (always service_period_max)
local function insert_fuel(o, default_use_reserved)
  local inventory = o.entity.get_fuel_inventory()
  if inventory and #inventory >= 1 then
    insert_using_priority_set(
      o, ItemPriorityManager.get_fuel_key(o.entity.name),
      inventory[1], nil,
      default_use_reserved
    )
  end
  return service_period_max
end

-------------------------------------------------------------------------------

local function GetRecipeInfo_Furnace(recipe, entity, asi)
  local max_mult = 9999
  local out_capacity = {} -- debug
  local out_recipes = {}  -- debug

  log(("GetRecipeInfo_Furnace(%s, %s)"):format(recipe.name, entity.name))
  log((" - ing  = %s"):format(serpent.line(recipe.ingredients)))
  log((" - prod = %s"):format(serpent.line(recipe.products)))

  for _, prod in pairs(recipe.products) do
    if prod.type == "item" then
      local item_proto = game.item_prototypes[prod.name]
      local n_inserted = item_proto.stack_size
      out_capacity[prod.name] = n_inserted

      local prod_amount
      if prod.amount ~= nil then
        prod_amount = prod.amount
      else
        prod_amount = prod.amount_max
      end
      if prod_amount > item_proto.stack_size then
        prod_amount = item_proto.stack_size
      end
      local mult = n_inserted / prod_amount
      max_mult = math.min(mult, max_mult)
      out_recipes[prod.name] = mult

    elseif prod.type == "fluid" then
      log(("TODO: fluid"))
      for i, fluid, filter, _ in Util.iter_fluidboxes(entity, "^", true) do
        local proto = entity.fluidbox.get_prototype(i)
        log((" - fbox i=%s fluid=%s filter=%s proto=%s pidx=%s vol=%s area=%s"):format(
          i,
          serpent.line(fluid),
          serpent.line(filter),
          proto,
          proto.index,
          proto.volume,
          proto.area
        ))
        for k, b in pairs(proto) do
          print(k, b.index, b.volume)
        end
      end
      --[[
      local fluid_proto = game.fluid_prototypes[prod.name]
      -- TODO: find the fluidbox
      out_capacity[prod.name] = n_inserted
      local mult
      if prod.amount ~= nil then
        mult = n_inserted / prod.amount
      else
        mult = n_inserted / prod.amount_max
      end
      max_mult = math.min(mult, max_mult)
      out_recipes[prod.name] = mult
      ]]
    end
  end

  local inp_capacity = {} -- debug
  local inp_recipes = {}  -- debug
  for _, ing in pairs(recipe.ingredients) do
    if ing.type == "item" then
      local item_proto = game.item_prototypes[ing.name]
      local n_inserted = item_proto.stack_size * 2
      inp_capacity[ing.name] = n_inserted

      log((" - ing ss = %s"):format(n_inserted))

      local mult = n_inserted / ing.amount
      inp_recipes[ing.name] = mult
      max_mult = math.min(mult, max_mult)

    elseif ing.type == "fluid" then
      -- TODO: find 'input' or 'input-output' fluid boxes with the filter
      --[[
      local n_inserted = entity.insert_fluid({ name=ing.name, amount=999999 })
      inp_capacity[ing.name] = n_inserted
      local mult = n_inserted / ing.amount
      inp_recipes[ing.name] = mult
      max_mult = math.min(mult, max_mult)
      ]]
    end
  end

  asi.max_multiplier = max_mult

  -- DEBUG:
  log((" - inp_cap = %s"):format(serpent.line(inp_capacity)))
  log((" - inp_rec = %s"):format(serpent.line(inp_recipes)))
  log((" - out_cap = %s"):format(serpent.line(out_capacity)))
  log((" - out_rec = %s"):format(serpent.line(out_recipes)))
  log((" - mult    = %s"):format(asi.max_multiplier))
  return asi
end

--[[
Determine the maximum recipe multiplier for this recipe that
will fit in this assembler.
This should not depend on beacons.

Cached info is stored as:
  global.recipe_info[recipe.name][assembler_name] = {
    item_multiplier=2,
    fluid_multiplier=1,
    max_multiplier=2
  }

TODO: Split items from fluids as above!
FIXME: this does not work on furnaces if they are crafting the wrong thing!
  Assume 2 stack input and 1 stack output for furnaces if the results are zero?
  Don't save it, though.
]]
local function GetRecipeInfo(recipe, entity, storage)
  if global.recipe_info == nil then
    global.recipe_info = {}
  end
  local rin = global.recipe_info[recipe.name]
  if rin == nil then
    rin = {}
    global.recipe_info[recipe.name] = rin
  end
  local asi = rin[entity.name]
  if asi == nil then
    asi = {}
    rin[entity.name] = asi
  end

  if next(asi) == nil then
    if entity.type == "furnace" then
      GetRecipeInfo_Furnace(recipe, entity, asi)
      return asi
    end
    log(("Not a furnace: %s"):format(entity.type))
    local out_inventory = entity.get_inventory(defines.inventory.assembling_machine_output)
    local inp_inventory = entity.get_inventory(defines.inventory.assembling_machine_input)
    Storage.add_from_inventory(storage, out_inventory, true)
    Storage.add_from_inventory(storage, inp_inventory, true)
    -- dump both input and output fluids
    store_fluids(storage, entity, nil, true)

    -- should be no-ops, unless the item can't be stored. then it is lost.
    -- but this only happens once.
    out_inventory.clear()
    inp_inventory.clear()
    entity.clear_fluid_inside()

    log(("GetRecipeInfo(%s, %s)"):format(recipe.name, entity.name))
    log((" - ing  = %s"):format(serpent.line(recipe.ingredients)))
    log((" - prod = %s"):format(serpent.line(recipe.products)))

    local max_mult = 9999
    local out_capacity = {} -- debug
    local out_recipes = {}  -- debug
    for _, prod in pairs(recipe.products) do
      if prod.type == "item" then
        local n_inserted = out_inventory.insert({ name=prod.name, count=65535 })
        out_capacity[prod.name] = n_inserted

        local prod_amount
        if prod.amount ~= nil then
          prod_amount = prod.amount
        else
          prod_amount = prod.amount_max
        end
        local item_proto = game.item_prototypes[prod.name]
        if item_proto ~= nil and prod_amount > item_proto.stack_size then
          prod_amount = item_proto.stack_size
        end
        local mult = n_inserted / prod_amount
        max_mult = math.min(mult, max_mult)
        out_recipes[prod.name] = mult

      elseif prod.type == "fluid" then
        log((" - fluid = %s"):format(prod.name))
        local n_inserted = entity.insert_fluid({ name=prod.name, amount=999999 })
        out_capacity[prod.name] = n_inserted
        local mult
        if prod.amount ~= nil then
          mult = n_inserted / prod.amount
        else
          mult = n_inserted / prod.amount_max
        end
        max_mult = math.min(mult, max_mult)
        out_recipes[prod.name] = mult

        --[[
        for i, fluid, filter, _ in Util.iter_fluidboxes(entity, "^", true) do
          local proto = entity.fluidbox.get_prototype(i)
          log((" - fbox i=%s fluid=%s filter=%s proto=%s pidx=%s vol=%s area=%s"):format(
            i,
            serpent.line(fluid),
            serpent.line(filter),
            proto,
            proto.index,
            proto.volume,
            proto.area
          ))
          for k, b in pairs(proto) do
            print(k, b.index, b.volume)
          end
        end
        ]]
      end
    end
    out_inventory.clear()
    entity.clear_fluid_inside()

    local inp_capacity = {} -- debug
    local inp_recipes = {}  -- debug
    for _, ing in pairs(recipe.ingredients) do
      if ing.type == "item" then
        local n_inserted = inp_inventory.insert({ name=ing.name, count=9999 })
        inp_capacity[ing.name] = n_inserted
        local mult = n_inserted / ing.amount
        inp_recipes[ing.name] = mult
        max_mult = math.min(mult, max_mult)
      elseif ing.type == "fluid" then
        local n_inserted = entity.insert_fluid({ name=ing.name, amount=999999 })
        inp_capacity[ing.name] = n_inserted
        local mult = n_inserted / ing.amount
        inp_recipes[ing.name] = mult
        max_mult = math.min(mult, max_mult)
      end
    end
    inp_inventory.clear()
    entity.clear_fluid_inside()

    local mm = math.ceil(max_mult)
    if mm > 0 then
      asi.max_multiplier = mm
    end

    -- DEBUG:
    log((" - inp_cap = %s"):format(serpent.line(inp_capacity)))
    log((" - inp_rec = %s"):format(serpent.line(inp_recipes)))
    log((" - out_cap = %s"):format(serpent.line(out_capacity)))
    log((" - out_rec = %s"):format(serpent.line(out_recipes)))
    log((" - mult    = %s"):format(asi.max_multiplier))
  end
  return asi
end

local assembling_machine_period_min = 120
local assembling_machine_period_max = TARGET_INGREDIENT_CRAFT_TIME * 60

function EntityHandlers.handle_assembler(o, override_recipe, clear_inputs)
  local entity, storage = o.entity, o.storage
  local recipe = override_recipe or entity.get_recipe()
  if recipe == nil then
    o.data.old_recipe = nil
    return assembling_machine_period_max
  end
  o.data.old_recipe = recipe.name

  -- get the cached max_multiplier based on the assembler and recipe
  local max_multiplier = GetRecipeInfo(recipe, entity, storage).max_multiplier
  if not max_multiplier then
    return assembling_machine_period_max
  end

  -- always try to pick up outputs, even if disabled
  local output_inventory = entity.get_inventory(defines.inventory.assembling_machine_output)
  local _, remaining_items = Storage.add_from_inventory(storage, output_inventory, false)

  -- REVISIT: is this still true?
  -- TODO: we're storing all fluids here, so a recipe that has the same input and output fluid
  -- might get stuck as the output will be stored first
  Util.dictionary_merge(remaining_items, store_fluids(storage, entity, "^output"))

  if o.paused then
    return assembling_machine_period_max
  end

  local input_inventory = entity.get_inventory(defines.inventory.assembling_machine_input)

  -- if we have any stuck outputs, then remove the inputs and wait for the max period
  if next(remaining_items) then
    --log(("[%s] %s r=%s output stuck"):format(entity.unit_number, entity.name, recipe.name))
    Storage.add_from_inventory(storage, input_inventory, false)
    return assembling_machine_period_max
  end

  -- FIXME: need the max period from the fuel
  local inserted = insert_fuel(o, false)

  local recipe_ticks = recipe.energy / entity.crafting_speed * 60

  local crafts_per_second = entity.crafting_speed / recipe.energy
  local ingredient_multiplier = math.min(max_multiplier, math.ceil(TARGET_INGREDIENT_CRAFT_TIME * crafts_per_second))

  if ingredient_multiplier < 1 then
    log(("  -- energy=%s crafting_speed=%s rt=%s mm=%s"):format(recipe.energy, entity.crafting_speed, recipe_ticks, max_multiplier))
  end

  if clear_inputs then
    Storage.add_from_inventory(storage, input_inventory, true)
    store_fluids(storage, entity, nil, true)
  end
  local input_items = input_inventory.get_contents()
  for i, fluid, filter, proto in Util.iter_fluidboxes(entity, "^", false) do
    if proto.production_type ~= "output" then
      local storage_key = Storage.get_fluid_storage_key(fluid.name)
      input_items[storage_key] = math.floor(fluid.amount)
    end
  end
  -- reduce the multiplier if we don't have enough of an ingredient
  for _, ingredient in ipairs(recipe.ingredients) do
    local storage_key, storage_amount
    if ingredient.type == "fluid" then
      storage_key = Storage.get_fluid_storage_key(ingredient.name)
      storage_amount = Storage.count_available_fluid_in_temperature_range(
        storage,
        storage_key,
        ingredient.minimum_temperature,
        ingredient.maximum_temperature,
        o.use_reserved
      )
    else
      storage_key = ingredient.name
      storage_amount = Storage.get_available_item_count(
        storage, storage_key,
        ingredient.amount * ingredient_multiplier, o.use_reserved
      )
    end
    local craftable_ratio = math.floor((storage_amount + (input_items[storage_key] or 0)) / math.ceil(ingredient.amount))


    --log(("[%s] %s t=%s amt=%s cr=%s sa=%s mp=%s"):format(entity.unit_number, entity.name, storage_key, ingredient.amount, craftable_ratio, storage_amount, max_period))

    ingredient_multiplier = Util.clamp(craftable_ratio, 1, ingredient_multiplier)
  end

--[[
calculate time for one recipe. Get multiplier based on that and max period.
Get current inputs.
Get available inputs.
Reduce the multiplier based on the max number of recipes based on available inputs.
Add ingredients. If unable to add items, then ...
  Get current inputs.
  Calculate the max number of recipes based on actualy contents.
  Save this in entity_data. It won't change.
Set timeout to handle the number of recipes. (Service when recipes should be done.)

-- if the actual max is less than

 359.744 Script @__auto-resource-redux__/src/EntityHandlers.lua:287: [119] rocket-silo name=low-density-structure amt=1 cr=32 sa=25
 359.744 Script @__auto-resource-redux__/src/EntityHandlers.lua:287: [119] rocket-silo name=rocket-control-unit amt=1 cr=32 sa=25
 359.744 Script @__auto-resource-redux__/src/EntityHandlers.lua:287: [119] rocket-silo name=rocket-fuel amt=3 cr=25 sa=75
 359.744 Script @__auto-resource-redux__/src/EntityHandlers.lua:287: [119] rocket-silo name=se-heat-shielding amt=1 cr=32 sa=25
 359.745 Script @__auto-resource-redux__/src/EntityHandlers.lua:317: [119] rocket-silo r=rocket-part mult=25 i={{amount = 1, name = "low-density-structure", type = "item"}, {amount = 1, name = "rocket-control-unit", type = "item"}, {amount = 3, name = "rocket-fuel", type = "item"}, {amount = 1, name = "se-heat-shielding", type = "item"}}

]]

  -- insert ingredients
  local fluid_targets = {}
  for _, ingredient in ipairs(recipe.ingredients) do
    local target_amount = math.ceil(ingredient.amount) * ingredient_multiplier
    if ingredient.type == "fluid" then
      fluid_targets[ingredient.name] = {
        amount = target_amount,
        min_temp = ingredient.minimum_temperature,
        max_temp = ingredient.maximum_temperature,
      }
    else
      local amount_needed = target_amount - (input_items[ingredient.name] or 0)
      if amount_needed > 0 then
        local amount_inserted = Storage.put_in_inventory(
          storage, input_inventory,
          ingredient.name, amount_needed,
          o.use_reserved
        )
        inserted = inserted or (amount_inserted > 0)
      end
    end
  end

  -- local contents = input_inventory.get_contents()

  local period = Util.clamp(math.floor(ingredient_multiplier * recipe_ticks),
    assembling_machine_period_min, assembling_machine_period_max)
  --local period = math.max(math.min(, assembling_machine_period_max)

  --log(("[%s] %s r=%s mult=%s period=%s"):format(entity.unit_number, entity.name, recipe.name, ingredient_multiplier, period))

  insert_fluids(o, fluid_targets)
  --return inserted
  if entity.status == defines.entity_status.working then
    return period
  end
  return assembling_machine_period_max
end

function EntityHandlers.handle_furnace(o)
  local recipe, switched = FurnaceRecipeManager.get_new_recipe(o.entity)
  if not recipe then
    return false
  end
  return EntityHandlers.handle_assembler(o, recipe, switched)
end

function EntityHandlers.handle_rocket_silo(o)
  local out_inv = o.entity.get_inventory(defines.inventory.rocket_silo_output)
  if out_inv ~= nil then
    Storage.add_from_inventory(o.storage, out_inv, false)
  end

  local recipe = o.entity.get_recipe()
  local inp_inv = o.entity.get_inventory(defines.inventory.rocket_silo_input)

  if recipe ~= nil and inp_inv ~= nil then
    return EntityHandlers.handle_assembler(o, recipe, false)
  end

  return service_period_max
end

--[[
Labs are always serviced at the maximum interval.
We stock enough science packs to last the whole time.
We could go longer than the maximum interval in early game, as it can take 30+
seconds for one science pack cycle.
]]
function EntityHandlers.handle_lab(o)
  if o.paused then
    return service_period_max
  end

  local entity = o.entity
  local prot = entity.prototype

  -- base is one for current and one for next
  local pack_count_target = 2

  -- if we have current_research, we can make a better estimate
  local cur_res = entity.force.current_research
  if cur_res ~= nil then
    -- calculate the number of ticks for one complete cycle
    local one_ticks = math.floor(cur_res.research_unit_energy / (prot.researching_speed + entity.speed_bonus))
    if one_ticks > 0 then
      pack_count_target = 1 + math.ceil(service_period_max / one_ticks)
    end
  end

  local lab_inv = entity.get_inventory(defines.inventory.lab_input)

  for i, item_name in ipairs(prot.lab_inputs) do
    Storage.add_to_or_replace_stack(
      o.storage, item_name,
      lab_inv[i], pack_count_target,
      false, o.use_reserved
    )
  end

  insert_fuel(o, false)

  return service_period_max
end

-- FIXME: if a mining drill doesn't use fuel AND it doesn't output fluids, then
--    there is no reason to service it at all. Unless we start to provide mining fluid.
function EntityHandlers.handle_mining_drill(o)
  if o.paused then
    return service_period_max
  end

  -- TODO: if this doesn't take fuel AND it does not need or produce fluid, then
  --       we can stop servicing it.

  insert_fuel(o, false)
  if #o.entity.fluidbox > 0 then
    -- there is no easy way to know what fluid a miner wants, the fluid is a property of the ore's prototype
    -- and the expected resources aren't simple to find: https://forums.factorio.com/viewtopic.php?p=247019
    -- so it will have to be done manually using the fluid access tank
    local _, inserted = store_fluids(o.storage, o.entity, "^output$")
  end
  return service_period_max
end

-- Generic refuel-only handler
function EntityHandlers.handle_boiler(o)
  if o.paused then
    return false
  end
  return insert_fuel(o, true)
end

-- Generic refuel-only handler
function EntityHandlers.handle_burner_generator(o)
  if o.paused then
    return false
  end
  return insert_fuel(o, true)
end

-- REVISIT: reactors don't burn fuel fast, so always use the max period
function EntityHandlers.handle_reactor(o)
  if o.paused then
    return service_period_max
  end
  local busy = insert_fuel(o, true)
  local result_inventory = o.entity.get_burnt_result_inventory()
  if result_inventory then
    local added_items = Storage.add_from_inventory(o.storage, result_inventory, false)
    busy = table_size(added_items) > 0 or busy
  end
  return service_period_max
end

-- TODO: calculate the max fire rate / ammo consumption to determine optimal service period?
function EntityHandlers.handle_turret(o)
  if o.paused then
    return false
  end
  local inventory = o.entity.get_inventory(defines.inventory.turret_ammo)
  if inventory and #inventory >= 1 then
    return insert_using_priority_set(
      o, ItemPriorityManager.get_ammo_key(o.entity.name, 1),
      inventory[1], nil,
      true
    )
  end
  return false
end

function EntityHandlers.handle_car(o, ammo_inventory_id)
  if o.paused then
    return false
  end
  local busy = insert_fuel(o, true)
  local ammo_inventory = o.entity.get_inventory(ammo_inventory_id or defines.inventory.car_ammo)
  if ammo_inventory then
    for i = 1, #ammo_inventory do
      busy = insert_using_priority_set(
        o, ItemPriorityManager.get_ammo_key(o.entity.name, i),
        ammo_inventory[i], ammo_inventory.get_filter(i),
        true
      ) or busy
    end
  end

  if o.data.collect_inv == nil then
    -- special support for vehicle-miner
    if string.find(o.entity.name, "-miner") ~= nil then
      log(("determinging collect inv for %s == true"):format(o.entity.name))
      o.data.collect_inv = true
    else
      log(("determinging collect inv for %s == false"):format(o.entity.name))
      o.data.collect_inv = false
    end
  end

  if o.data.collect_inv == true then
    local trunk_inv = o.entity.get_output_inventory()
    if trunk_inv then
      Storage.add_from_inventory(o.storage, trunk_inv, false)
    end
  end
  return busy
end

function EntityHandlers.handle_spidertron(o)
  local busy = EntityHandlers.handle_car(o, defines.inventory.spider_ammo)
  return LogisticManager.handle_spidertron_requests(o) or busy
end

function EntityHandlers.handle_sink_chest(o, ignore_limit)
  local inventory = o.entity.get_inventory(defines.inventory.chest)
  local added_items, _ = Storage.add_from_inventory(o.storage, inventory, ignore_limit)
  return table_size(added_items) > 0
end

function EntityHandlers.handle_sink_tank(o)
  if o.paused then
    return service_period_max
  end

  local fluidbox = o.entity.fluidbox
  local fluid = fluidbox[1]

  if fluid == nil or fluid.amount < 1 then
    return service_period_max -- tank is empty
  end

  local new_fluid, amount_added = Storage.add_fluid(o.storage, fluid)
  if amount_added > 0 then
    o.entity.fluidbox[1] = new_fluid.amount > 0 and new_fluid or nil

    -- calculate the optimal service_period based on the amount delivered
    local capacity = fluidbox.get_capacity(1)

    local period = o.data.period or service_period_min
    if amount_added >= (0.95 * capacity) then
      -- added over 95%, chop period in half
      period = period / 2
    elseif amount_added < (0.05 * capacity) then
      -- added less than 5%, double period in half
      period = period * 2
    else
      -- in the middle, so calculate the optimal period
      local last_period = game.tick - (o.data._service_tick or 0)
      period = math.floor(last_period * (capacity * 0.9) / amount_added)
    end
    period = math.max(service_period_min, math.min(service_period_max, period))
    o.data.period = period
    return period
  end

  -- not feeding the network, must be full
  return service_period_max
end

local tank_min_period = 60
local tank_max_period = 10 * 60

function EntityHandlers.handle_requester_tank(o)
  local data = global.entity_data[o.entity.unit_number]
  -- autoconfig
  if data == nil or not data.fluid then
    data = data or {}
    if not FluidBoxScan.autoconfig_request(o.entity, data) then
      return service_period_max
    end
    global.entity_data[o.entity.unit_number] = data
  end
  if o.paused then
    return service_period_max
  end
  local fluid = o.entity.fluidbox[1]
  if fluid and data.fluid and fluid.name ~= data.fluid then
    Storage.add_fluid(o.storage, fluid, true)
    o.entity.fluidbox[1] = nil
    fluid = nil
  end
  fluid = fluid or {
    name = data.fluid,
    amount = 0,
    temperature = Util.get_default_fluid_temperature(data.fluid)
  }
  local capacity = o.entity.fluidbox.get_capacity(1)
  local target_amount = math.floor(data.percent / 100 * capacity)
  local amount_needed = target_amount - fluid.amount
  if amount_needed <= 0 then
    return service_period_max
  end
  local amount_removed, temperature = Storage.remove_fluid_in_temperature_range(
    o.storage,
    Storage.get_fluid_storage_key(fluid.name),
    data.min_temp,
    data.max_temp or data.min_temp,
    amount_needed,
    o.use_reserved
  )
  if amount_removed > 0 then
    fluid.temperature = Util.weighted_average(fluid.temperature, fluid.amount, temperature, amount_removed)
    fluid.amount = fluid.amount + amount_removed
    o.entity.fluidbox[1] = fluid

    -- calculate the optimal rate based on how much was added vs capacity. target is 90% fill.
    local period = o.data.period or service_period_min

    if amount_removed >= (0.95 * target_amount) then
      -- added over 95%, chop period in half
      period = period / 2
    elseif amount_removed < (0.05 * target_amount) then
      -- added less than 5%, double period in half
      period = period * 2
    else
      -- in the middle, so calculate the optimal period
      local last_period = game.tick - (o.data._service_tick or 0)
      period = math.floor(last_period * (target_amount * 0.9) / amount_removed)
    end

    -- clamp the period to the allowed range
    period = math.min(service_period_max, math.max(service_period_min, period))
    o.data.period = period
    return period
  end
  return service_period_max
end

function EntityHandlers.handle_storage_combinator(o)
  local entity = o.entity
  local cb = entity.get_control_behavior()
  if o.paused or not cb.enabled then
    cb.parameters = {}
    return true
  end

  local storage = EntityCondition.get_selected_storage(entity, o.condition, o.storage)
  if not storage then
    cb.parameters = {}
    return true
  end

  local cache, cache_key = o.cache, storage.domain_key
  if cache[cache_key] then
    cb.parameters = cache[cache_key]
    return true
  end

  local params = {}
  local i = 1
  for name, count in pairs(storage.items) do
    local fluid_name = Storage.unpack_fluid_item_name(name)
    table.insert(
      params,
      {
        signal = {
          type = fluid_name and "fluid" or "item",
          name = fluid_name or name
        },
        count = fluid_name and Util.table_sum_vals(count) or count,
        index = i
      }
    )
    i = i + 1
  end
  cb.parameters = params
  cache[cache_key] = params
  return true
end


--[[
Revive a ghost, pull stuff out of storage.
]]
local function populate_ghost(o, is_entity)
  local entity = o.entity
  local ghost_prototype = entity.ghost_prototype
  if ghost_prototype == nil then
    return -1 -- stop processing!
  end
  local old_unum = entity.unit_number

  -- check to see if we have enough items in the network
  local item_list = ghost_prototype.items_to_place_this
  local missing = false
  for _, ing in ipairs(item_list) do
    local n_avail = Storage.get_available_item_count(o.storage, ing.name, ing.count, false)
    if n_avail < ing.count then
      missing = true
    end
  end
  if missing then
    -- waiting for items
    return 10*60
  end

  log(("Trying to revive %s @ %s"):format(entity.ghost_name, serpent.line(entity.position)))
  local _, revived_entity, __ = entity.revive{raise_revive = true}
  if revived_entity ~= nil then
    if old_unum ~= nil then
      global.entities[old_unum] = nil
    end

    -- NOTE: entity is now invalid
    for _, ing in ipairs(item_list) do
      Storage.remove_item(o.storage, ing.name, ing.count, true)
    end
    return -1
  end

  local period = service_period_max

  if is_entity then
    -- instantly deconstruct anything that should be deconstructed
    local ents = entity.surface.find_entities_filtered({ area=entity.bounding_box, to_be_deconstructed=true })
    local to_mine = {}
    for _, eee in ipairs(ents) do
      if eee.prototype.mineable_properties.minable then
        table.insert(to_mine, eee)
      else
        --log(("%s %s is blocking @ %s : %s"):format(eee.name, eee.type, serpent.line(eee.position), entity.ghost_name))
        Destroyer.queue_destruction(eee, entity.force)
        period = 120
      end
    end

    if #to_mine > 0 then
      local inv = game.create_inventory(16)
      for _, eee in ipairs(to_mine) do
        eee.mine({ inventory=inv })
        period = service_period_min
      end
      for name, count in pairs(inv.get_contents()) do
        Storage.add_item_or_fluid(o.storage, name, count, true, nil)
      end
      inv.destroy()
    end
  end

  -- failed: likely blocked, try again later
  return period
end

function EntityHandlers.handle_entity_ghost(o)
  return populate_ghost(o, true)
end

function EntityHandlers.handle_tile_ghost(o)
  return populate_ghost(o, false)
end

-- Special assembling-machine that gets one more drone per service
function EntityHandlers.handle_mining_depot(o)
  local entity = o.entity
  local recipe = entity.get_recipe()
  local inp_inventory = entity.get_inventory(defines.inventory.assembling_machine_input)
  local out_inventory = entity.get_inventory(defines.inventory.assembling_machine_output)
  local period = service_period_max

  -- dump the output inventory
  Storage.add_from_inventory(o.storage, out_inventory, false)

  -- try to add one more drone
  if recipe ~= nil and inp_inventory ~= nil then
    for _, ing in pairs(recipe.ingredients) do
      local n_added = Storage.put_in_inventory(o.storage, inp_inventory, ing.name, 1, false)
      if n_added > 0 then
        period = 2 * 60
      end
    end
  end
  return period
end

return EntityHandlers
