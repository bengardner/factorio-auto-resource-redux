local EntityHandlers = {}

-- seconds to attempt to keep assemblers fed for
local TARGET_INGREDIENT_CRAFT_TIME = 2

local ItemPriorityManager = require "src.ItemPriorityManager"
local Storage = require "src.Storage"
local Util = require "src.Util"

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

local function insert_fluids(storage, entity, target_amounts, default_amount)
  default_amount = default_amount or 0
  local inserted = false
  for i, fluid, filter, proto in Util.iter_fluidboxes(entity, "^", true) do
    if not filter or proto.production_type == "output" then
      goto continue
    end
    fluid = fluid or { name = filter.name, amount = 0 }
    local target_amount = (target_amounts[filter.name] or default_amount)
    if target_amount <= 0 then
      goto continue
    end
    local amount_needed = math.max(0, target_amount - fluid.amount)
    local amount_removed = Storage.remove_fluid_in_temperature_range(
      storage,
      Storage.get_fluid_storage_key(filter.name),
      filter.minimum_temperature,
      filter.maximum_temperature,
      amount_needed
    )
    inserted = true
    -- We could compute the new temperature but recipes don't take the specific temperature into account
    fluid.amount = fluid.amount + amount_removed
    entity.fluidbox[i] = fluid.amount > 0 and fluid or nil
    ::continue::
  end
  return inserted
end

local function insert_using_priority_set(storage, entity, priority_set_key, stack, filter_name)
  local priority_sets = ItemPriorityManager.get_priority_sets(entity)
  if not priority_sets[priority_set_key] then
    log(("FIXME: missing priority set \"%s\" for %s!"):format(priority_set_key, entity.name))
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

  -- insert first usable item
  for item_name, wanted_amount in pairs(usable_items) do
    local stored_amount = storage.items[item_name] or 0
    if wanted_amount <= 0 then
      goto continue
    end
    if stored_amount > 0 then
      if item_name == current_item then
        stored_amount = stored_amount + current_count
      end
      local new_satisfaction = math.min(1, stored_amount / wanted_amount)

      if new_satisfaction >= current_satisfaction then
        local amount_added = Storage.add_to_or_replace_stack(storage, stack, item_name, wanted_amount, true)
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

local function insert_fuel(storage, entity)
  local inventory = entity.get_fuel_inventory()
  if inventory then
    return insert_using_priority_set(
      storage,
      entity,
      ItemPriorityManager.get_fuel_key(entity.name),
      inventory[1]
    )
  end
  return false
end

function EntityHandlers.handle_assembler(entity, secondary_recipe)
  local recipe = entity.get_recipe() or secondary_recipe
  if recipe == nil then
    return false
  end

  -- always try to pick up outputs
  local storage = Storage.get_storage(entity)
  local output_inventory = entity.get_inventory(defines.inventory.assembling_machine_output)
  local _, remaining_items = Storage.take_all_from_inventory(storage, output_inventory)
  -- TODO: we're storing all fluids here, so a recipe that has the same input and output fluid
  -- might get stuck as the output will be stored first
  Util.dictionary_merge(remaining_items, store_fluids(storage, entity))

  -- check if we should craft
  local has_empty_slot = false
  for _, item in ipairs(recipe.products) do
    local amount_produced = item.amount or item.amount_max
    local storage_key = item.name
    if item.type == "fluid" then
      storage_key = Storage.get_fluid_storage_key(item.name)
    end

    if remaining_items[storage_key] == nil then
      has_empty_slot = true
    end

    -- skip crafting if any slot contains 1x or more products
    if (remaining_items[storage_key] or 0) >= amount_produced then
      return false
    end
  end
  if not has_empty_slot then
    return false
  end

  local crafts_per_second = entity.crafting_speed / recipe.energy
  local ingredient_multiplier = math.max(1, math.ceil(TARGET_INGREDIENT_CRAFT_TIME * crafts_per_second))
  local input_inventory = entity.get_inventory(defines.inventory.assembling_machine_input)
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
      storage_amount = Storage.count_fluid_in_temperature_range(
        storage,
        storage_key,
        ingredient.minimum_temperature,
        ingredient.maximum_temperature
      )
    else
      storage_key = ingredient.name
      storage_amount = storage.items[storage_key] or 0
    end
    local craftable_ratio = math.floor((storage_amount + (input_items[storage_key] or 0)) / math.ceil(ingredient.amount))
    ingredient_multiplier = Util.clamp(craftable_ratio, 1, ingredient_multiplier)
  end

  -- insert ingredients
  local fluid_targets = {}
  local inserted = false
  for _, ingredient in ipairs(recipe.ingredients) do
    local target_amount = math.ceil(ingredient.amount) * ingredient_multiplier
    if ingredient.type == "fluid" then
      fluid_targets[ingredient.name] = target_amount
    else
      local amount_needed = target_amount - (input_items[ingredient.name] or 0)
      if amount_needed > 0 then
        local amount_inserted = Storage.put_in_inventory(storage, input_inventory, ingredient.name, amount_needed)
        inserted = inserted or (amount_inserted > 0)
      end
    end
  end
  inserted = inserted or insert_fluids(storage, entity, fluid_targets)
  return inserted
end

function EntityHandlers.handle_furnace(entity)
  local recipe = entity.get_recipe() or entity.previous_recipe
  local busy = false
  if recipe then
    local storage = Storage.get_storage(entity)
    busy = busy or insert_fuel(storage, entity)
    busy = busy or EntityHandlers.handle_assembler(entity, recipe)
  end
  return busy
end

function EntityHandlers.handle_lab(entity)
  local pack_count_target = math.ceil(entity.speed_bonus * 0.5) + 1
  local lab_inv = entity.get_inventory(defines.inventory.lab_input)
  local storage = Storage.get_storage(entity)
  local inserted = false
  for i, item_name in ipairs(game.entity_prototypes[entity.name].lab_inputs) do
    local amount_inserted = Storage.add_to_or_replace_stack(storage, lab_inv[i], item_name, pack_count_target)
    inserted = inserted or (amount_inserted > 0)
  end
  return inserted
end

function EntityHandlers.handle_mining_drill(entity)
  local storage = Storage.get_storage(entity)
  local busy = insert_fuel(storage, entity)
  if #entity.fluidbox > 0 then
    -- there is no easy way to know what fluid a miner wants, the fluid is a property of the ore's prototype
    -- and the expected resources aren't simple to find: https://forums.factorio.com/viewtopic.php?p=247019
    -- so it will have to be done manually using the fluid access tank
    local _, inserted = store_fluids(storage, entity, "^output$")
    busy = busy or inserted
  end
  return busy
end

function EntityHandlers.handle_boiler(entity)
  local storage = Storage.get_storage(entity)
  return insert_fuel(storage, entity)
end

function EntityHandlers.handle_turret(entity)
  local storage = Storage.get_storage(entity)
  return insert_using_priority_set(
    storage,
    entity,
    ItemPriorityManager.get_ammo_key(entity.name, 1),
    entity.get_inventory(defines.inventory.turret_ammo)[1]
  )
end

function EntityHandlers.handle_car(entity)
  local storage = Storage.get_storage(entity)
  local busy = insert_fuel(storage, entity)
  local ammo_inventory = entity.get_inventory(defines.inventory.car_ammo)
  if ammo_inventory then
    for i = 1, #ammo_inventory do
      busy = busy or insert_using_priority_set(
        storage,
        entity,
        ItemPriorityManager.get_ammo_key(entity.name, i),
        ammo_inventory[i],
        ammo_inventory.get_filter(i)
      )
    end
  end
  return busy
end

function EntityHandlers.handle_sink_chest(entity, ignore_limit)
  local storage = Storage.get_storage(entity)
  local inventory = entity.get_inventory(defines.inventory.chest)
  local added_items, _ = Storage.take_all_from_inventory(storage, inventory, ignore_limit)
  return table_size(added_items) > 0
end

function EntityHandlers.handle_sink_tank(entity)
  local storage = Storage.get_storage(entity)
  local fluid = entity.fluidbox[1]
  if fluid == nil then
    return false
  end
  local new_fluid, amount_added = Storage.add_fluid(storage, fluid)
  if amount_added > 0 then
    entity.fluidbox[1] = new_fluid.amount > 0 and new_fluid or nil
    return true
  end
  return false
end

function EntityHandlers.handle_requester_tank(entity)
  local data = global.entity_data[entity.unit_number]
  if not data then
    return false
  end
  local storage = Storage.get_storage(entity)
  local fluid = entity.fluidbox[1]
  if fluid and fluid.name ~= data.fluid then
    Storage.add_fluid(storage, fluid, true)
    fluid = nil
  end
  if not data.fluid then
    return false
  end
  fluid = fluid or {
    name = data.fluid,
    amount = 0,
    temperature = Util.get_default_fluid_temperature(data.fluid)
  }
  local capacity = entity.fluidbox.get_capacity(1)
  local target_amount = math.floor(data.percent / 100 * capacity)
  local amount_needed = target_amount - fluid.amount
  if amount_needed <= 0 then
    return false
  end
  local amount_removed, temperature = Storage.remove_fluid_in_temperature_range(
    storage,
    Storage.get_fluid_storage_key(fluid.name),
    data.min_temp,
    data.max_temp or data.min_temp,
    amount_needed
  )
  fluid.temperature = Util.weighted_average(fluid.temperature, fluid.amount, temperature, amount_removed)
  fluid.amount = fluid.amount + amount_removed
  if fluid.amount > 0 then
    entity.fluidbox[1] = fluid
    return true
  end
  return false
end

return EntityHandlers
