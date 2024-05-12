local EntityManager = {}

local EntityCondition = require "src.EntityCondition"
local EntityCustomData = require "src.EntityCustomData"
local EntityGroups = require "src.EntityGroups"
local EntityHandlers = require "src.EntityHandlers"
local FurnaceRecipeManager = require "src.FurnaceRecipeManager"
local LogisticManager = require "src.LogisticManager"
local DeadlineQueue = require "src.DeadlineQueue"
local Storage = require "src.Storage"
local Util = require "src.Util"

-- NOTE: a higher DEADLINE_QUEUE_TICKS wastes CPU, as we have to check if each entry has really expired.
-- Maybe go with 4 and use next_coarse() to skip the checks? Can be optimized later.
local DEADLINE_QUEUE_TICKS = 1
local DEADLINE_QUEUE_COUNT = 200
local SERVICE_PER_TICK_MIN = 20
local SERVICE_PER_TICK_MAX = 80

local evaluate_condition = EntityCondition.evaluate

-- number of ticks it takes to process the whole queue
local DEFAULT_TICKS_PER_CYCLE = 60
local entity_queue_specs = {
  ["sink-tank"] = { handler = EntityHandlers.handle_sink_tank },
  ["arr-requester-tank"] = { handler = EntityHandlers.handle_requester_tank },
  ["sink-chest"] = { handler = EntityHandlers.handle_sink_chest, ticks_per_cycle = 180 },
  ["logistic-sink-chest"] = { handler = LogisticManager.handle_sink_chest },
  ["logistic-requester-chest"] = { handler = LogisticManager.handle_requester_chest },
  ["car"] = { handler = EntityHandlers.handle_car },
  ["spidertron"] = { handler = EntityHandlers.handle_spidertron, ticks_per_cycle = 120 },
  ["artillery-turret"] = { handler = EntityHandlers.handle_turret },
  ["ammo-turret"] = { handler = EntityHandlers.handle_turret },
  ["boiler"] = { handler = EntityHandlers.handle_boiler, ticks_per_cycle = 120 },
  ["burner-generator"] = { handler = EntityHandlers.handle_burner_generator, ticks_per_cycle = 120 },
  ["reactor"] = { handler = EntityHandlers.handle_reactor, ticks_per_cycle = 120 },
  ["mining-drill"] = { handler = EntityHandlers.handle_mining_drill, ticks_per_cycle = 120 },
  ["furnace"] = { handler = EntityHandlers.handle_furnace, ticks_per_cycle = 120 },
  ["assembling-machine"] = { handler = EntityHandlers.handle_assembler, ticks_per_cycle = 120 },
  ["rocket-silo"] = { handler = EntityHandlers.handle_rocket_silo, ticks_per_cycle = 120 },
  ["lab"] = { handler = EntityHandlers.handle_lab, ticks_per_cycle = 120 },
  ["arr-combinator"] = { handler = EntityHandlers.handle_storage_combinator, ticks_per_cycle = 12 },
}

local function on_entity_removed(entity_id)
  EntityCustomData.on_entity_removed(entity_id)
  FurnaceRecipeManager.clear_marks(entity_id)
  global.entities[entity_id] = nil
end

--[[
Handle an entity.
Returns the number of ticks until the next service or -1 if the entity should be dropped.
]]
local function handle_entity(entity, cache_table)
  local queue_key = EntityGroups.names_to_groups[entity.name]
  if not queue_key then
    return -1 -- remove entity from queue
  end
  local specs = entity_queue_specs[queue_key]
  if not specs then
    return -1 -- remove entity from queue
  end
  local handler = entity_queue_specs[queue_key].handler
  if not handler then
    return -1 -- remove entity from queue
  end

  local entity_data = global.entity_data[entity.unit_number] or {}
  local storage = Storage.get_storage(entity)
  local running = not entity.to_be_deconstructed() and evaluate_condition(entity, entity_data.condition, storage)
  local dt = handler({
    entity = entity,
    data = entity_data,
    storage = storage,
    use_reserved = entity_data.use_reserved,
    paused = not running,
    return_excess = entity_data.return_excess,
    condition = entity_data.condition,
    cache = cache_table or {}
  })

  local last_service_tick = entity_data._service_tick
  if last_service_tick ~= nil then
    entity_data._service_period = game.tick - last_service_tick
  end
  entity_data._service_tick = game.tick
  if type(dt) == "number" then
    return dt
  end
  return specs.ticks_per_cycle or DEFAULT_TICKS_PER_CYCLE
end

local function manage_entity(entity, immediately_handle)
  local queue_key = EntityGroups.names_to_groups[entity.name]
  if queue_key == nil then
    return
  end

  log(string.format("Managing %d (name=%s, type=%s, queue=%s)", entity.unit_number, entity.name, entity.type, queue_key))
  global.entities[entity.unit_number] = entity
  local handler = entity_queue_specs[queue_key].handler
  local entity_data = global.entity_data[entity.unit_number]
  if entity_data == nil then
    entity_data = {}
    global.entity_data[entity.unit_number] = entity_data
  end

  local unit_number = entity.unit_number
  local dt = entity_queue_specs[queue_key].ticks_per_cycle or DEFAULT_TICKS_PER_CYCLE
  if immediately_handle then
    dt = handle_entity(entity)
  end
  if dt >= 0 and entity.valid then
    DeadlineQueue.queue(global.deadline_queue, entity.unit_number, entity_data, game.tick + dt)
    entity_data._deadline_add = game.tick
  else
    on_entity_removed(unit_number)
  end
  return queue_key
end

function EntityManager.reload_entities()
  log("Reloading entities")

  -- reset the deadline_queue
  global.deadline_queue = DeadlineQueue.new(DEADLINE_QUEUE_COUNT, DEADLINE_QUEUE_TICKS)

  local entity_names = Util.table_keys(EntityGroups.names_to_groups)
  for _, surface in pairs(game.surfaces) do
    local entities = surface.find_entities_filtered({ force = Util.table_keys(global.forces), name = entity_names })
    for _, entity in ipairs(entities) do
      manage_entity(entity)
    end
  end
end

function EntityManager.initialise()
  local should_reload_entities = false

  if global.sink_chest_parents == nil then
    global.sink_chest_parents = {}
  end
  if global.entities == nil then
    global.entities = {}
    should_reload_entities = true
  end

  if global.deadline_queue == nil then
    global.deadline_queue = DeadlineQueue.new(DEADLINE_QUEUE_COUNT, DEADLINE_QUEUE_TICKS)
    should_reload_entities = true
  elseif #global.deadline_queue ~= DEADLINE_QUEUE_COUNT then
    should_reload_entities = true
  end

  if not Util.same_value(EntityGroups.names_to_groups, global.names_to_groups) then
    should_reload_entities = true
    global.names_to_groups = EntityGroups.names_to_groups
    log(" ** names_to_groups changed!")
  end

  -- DEBUG/SANITY check: remove entities that are no longer are valid
  local rm_cnt = 0
  for unit_number, entity in pairs(global.entities) do
    if not entity.valid then
      on_entity_removed(unit_number)
      rm_cnt = rm_cnt + 1
    end
  end
  if rm_cnt > 0 then
    print((" *** REMOVED %s INVALID ENTITIES"):format(rm_cnt))
  end
  -- DEBUG end

  if should_reload_entities then
    EntityManager.reload_entities()
  end
  log(("Managing %s entities and %s names"):format(table_size(global.entities), table_size(EntityGroups.names_to_groups)))
end

-------------------------------------------------------------------------------

function EntityManager.on_tick()
  local now = game.tick
  local dlq = global.deadline_queue
  local ept = global.entities_per_tick or 20
  local cache_table = {}

  -- calculate the number of items to service on this tick.
  local cur_q_cnt = DeadlineQueue.get_current_count(dlq)
  local service_per_tick = math.max(SERVICE_PER_TICK_MIN, math.min(SERVICE_PER_TICK_MAX, cur_q_cnt / DEADLINE_QUEUE_TICKS))

  local processed_cnt = 0

  local hit_end = false
  for _ = 1, ept do
    local entity_id, _ = DeadlineQueue.next(dlq)
    if entity_id == nil then
      hit_end = true
      break
    end

    local entity = global.entities[entity_id]

    if entity == nil or not entity.valid then
      on_entity_removed(entity_id)
    else
      local dt = handle_entity(entity, cache_table)
      if dt >= 0 then
        -- FIXME: We should not be creating fake entity_data here!
        local entity_data = global.entity_data[entity_id] or {}
        DeadlineQueue.queue(dlq, entity_id, entity_data, now + dt)
        entity_data._deadline_add = now
        processed_cnt = processed_cnt + 1
      else
        -- We have a valid entity that we no longer service. drop it.
        on_entity_removed(entity_id)
      end
    end
  end

  -- adjust entities_per_tick based on load (TODO: tweak this!)
  if hit_end then
    -- hit the end of the list before we hit the limit
    ept = ept - 1
    if processed_cnt < SERVICE_PER_TICK_MIN then
      -- go down by 2 if we didn't even do the minimum
      ept = ept - 1
    end
  else
    -- still more to process
    ept = ept + 1
  end
  global.entities_per_tick = math.max(SERVICE_PER_TICK_MIN, math.min(ept, SERVICE_PER_TICK_MAX))
end

function EntityManager.on_entity_created(event)
  local entity = event.created_entity or event.destination or event.entity
  if not entity.valid then
    return
  end
  if global.forces[entity.force.name] == nil then
    return
  end
  local queue_key = manage_entity(entity, true)

  -- manage_entity() may have destroyed this entity via revive() or mine()
  if queue_key == nil or not entity.valid then
    return
  end

  -- place invisible chest to catch outputs for things like mining drills
  if entity.drop_position ~= nil and entity.drop_target == nil then
    local chest = entity.surface.create_entity({
      name = "arr-hidden-sink-chest",
      position = entity.drop_position,
      force = entity.force,
      player = entity.last_user,
      raise_built = true
    })
    if chest then
      chest.destructible = false
      global.sink_chest_parents[entity.unit_number] = chest.unit_number
    end
  end
end

function EntityManager.on_entity_removed(event, died)
  local entity = event.entity
  if entity.unit_number then
    on_entity_removed(entity.unit_number)
  end
  if not EntityGroups.can_manage(entity) then
    return
  end
  if not died and #entity.fluidbox > 0 then
    EntityHandlers.store_all_fluids(entity)
  end
  global.entities[entity.unit_number] = nil
  local attached_chest = global.entities[global.sink_chest_parents[entity.unit_number]]
  if attached_chest ~= nil and attached_chest.valid then
    if not died then
      EntityHandlers.handle_sink_chest(
        {
          entity = attached_chest,
          storage = Storage.get_storage(attached_chest),
          use_reserved = false,
        },
        true
      )
    end
    attached_chest.destroy({ raise_destroy = true })
  end
end

function EntityManager.on_entity_died(event)
  EntityManager.on_entity_removed(event, true)
end

function EntityManager.on_entity_replaced(data)
  EntityCustomData.migrate_data(data.old_entity_unit_number, data.new_entity_unit_number)
  manage_entity(data.new_entity, true)
end

function EntityManager.on_entity_deployed(data)
  manage_entity(data.entity, true)
end

return EntityManager
