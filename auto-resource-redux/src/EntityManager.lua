local EntityManager = {}

local EntityCondition = require "src.EntityCondition"
local EntityCustomData = require "src.EntityCustomData"
local EntityGroups = require "src.EntityGroups"
local EntityHandlers = require "src.EntityHandlers"
local FurnaceRecipeManager = require "src.FurnaceRecipeManager"
local LogisticManager = require "src.LogisticManager"
-- local LoopBuffer = require "src.LoopBuffer"
local Storage = require "src.Storage"
local Util = require "src.Util"
local Destroyer = require "src.Destroyer"
local DeadlineQueue = require "src.DeadlineQueue"

-- 10 seconds total
local DEADLINE_QUEUE_TICKS = 10
local DEADLINE_QUEUE_COUNT = 60

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
  ["lab"] = { handler = EntityHandlers.handle_lab, ticks_per_cycle = 120 },
  ["arr-combinator"] = { handler = EntityHandlers.handle_storage_combinator, ticks_per_cycle = 12 },
  ["entity-ghost"] = { handler = EntityHandlers.handle_entity_ghost, ticks_per_cycle = 120 },
  ["tile-ghost"] = { handler = EntityHandlers.handle_tile_ghost, ticks_per_cycle = 120 },
}

--[[
Handle an entity.
Returns the number of ticks until the next service.
]]
local function handle_entity(entity, cache_table)
  local queue_key = EntityGroups.names_to_groups[entity.name]
  if not queue_key then
    return -1
  end
  local specs = entity_queue_specs[queue_key]
  if not specs then
    return -1
  end
  local handler = entity_queue_specs[queue_key].handler
  if not handler then
    return -1 -- drop entity
  end

  local entity_data = global.entity_data[entity.unit_number] or {}
  local storage = Storage.get_storage(entity)
  local running = not entity.to_be_deconstructed() and evaluate_condition(entity, entity_data.condition, storage)
  local dt = handler({
    entity = entity,
    storage = storage,
    use_reserved = entity_data.use_reserved,
    paused = not running,
    return_excess = entity_data.return_excess,
    condition = entity_data.condition,
    cache = cache_table or {}
  })
  if type(dt) == "number" then
    return dt
  end
  return specs.ticks_per_cycle or 60
end

local function manage_entity(entity, immediately_handle)
  local queue_key = EntityGroups.names_to_groups[entity.name]
  if queue_key == nil then
    return
  end

  log(string.format("Managing %d (name=%s, type=%s, queue=%s)", entity.unit_number, entity.name, entity.type, queue_key))
  global.entities[entity.unit_number] = entity
  -- local queue = global.entity_queues[queue_key]
  local handler = entity_queue_specs[queue_key].handler
  --LoopBuffer.add(queue, entity.unit_number)
  local entity_data = global.entity_data[entity.unit_number]
  if entity_data == nil then
    entity_data = {}
    global.entity_data[entity.unit_number] = entity_data
  end

  local dt = 0
  if immediately_handle then
    dt = handle_entity(entity)
  end
  if dt >= 0 and entity.valid then
    DeadlineQueue.queue(global.deadline_queue, entity.unit_number, entity_data, game.tick + dt)
    entity_data._deadline_add = game.tick
  end
  return queue_key
end

function EntityManager.reload_entities()
  log("Reloading entities")
  --[[
  global.entity_queues = {}
  for queue_key, _ in pairs(entity_queue_specs) do
    global.entity_queues[queue_key] = LoopBuffer.new()
  end
  ]]
  -- reset the deadline_queue
  global.deadline_queue = DeadlineQueue.new(DEADLINE_QUEUE_COUNT, DEADLINE_QUEUE_TICKS)

  local entity_names = Util.table_keys(EntityGroups.names_to_groups)
  for _, surface in pairs(game.surfaces) do
    local entities = surface.find_entities_filtered({ force = Util.table_keys(global.forces), name = entity_names })
    for _, entity in ipairs(entities) do
      manage_entity(entity)
    end
  end

  log(("Managing %s entities"):format(table_size(global.entities)))

  --[[
  log("Entity queue sizes:")
  for entity_type, queue in pairs(global.entity_queues) do
    log(entity_type .. ": " .. queue.size)
  end
  ]]
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
  end
  -- FIXME : temp hack
  should_reload_entities = true

  --[[
  for queue_key, _ in pairs(entity_queue_specs) do
    if global.entity_queues == nil or global.entity_queues[queue_key] == nil then
      should_reload_entities = true
      break
    end
  end
  ]]

  if should_reload_entities then
    EntityManager.reload_entities()
  end
end

local function on_entity_removed(entity_id)
  EntityCustomData.on_entity_removed(entity_id)
  FurnaceRecipeManager.clear_marks(entity_id)
end

-------------------------------------------------------------------------------

--[[
local busy_counters = {}
function EntityManager.on_tick_loopbuffer()
  local total_processed = 0
  for queue_key, spec in pairs(entity_queue_specs) do
    local queue = global.entity_queues[queue_key]
    -- evenly distribute updates across the whole cycle
    local ticks_per_cycle = spec.ticks_per_cycle or DEFAULT_TICKS_PER_CYCLE
    local update_index = game.tick % ticks_per_cycle
    local max_updates = (
      math.floor(queue.size * (update_index + 1) / ticks_per_cycle) -
      math.floor(queue.size * update_index / ticks_per_cycle)
    )
    if max_updates <= 0 then
      goto continue
    end

    local num_processed = 0
    local cache_table = {}
    repeat
      if queue.size == 0 then
        break
      end
      local entity_id = LoopBuffer.next(queue)
      local entity = global.entities[entity_id]
      if entity == nil or not entity.valid then
        on_entity_removed(entity_id)
        LoopBuffer.remove_current(queue)
      else
        if handle_entity(entity, spec.handler, cache_table) then
          busy_counters[queue_key] = (busy_counters[queue_key] or 0) + 1
        end
        num_processed = num_processed + 1
      end
      if queue.iter_index == 1 and queue.size > 10 then
        -- local count = busy_counters[queue_key] or 0
        -- print(("%s: %d/%d (%.2f%%) busy, %d/%d (%.2f%%) idle, %d updates per tick"):format(
        --   queue_key,
        --   count,
        --   queue.size,
        --   count / queue.size * 100,
        --   (queue.size - count),
        --   queue.size,
        --   (queue.size - count) / queue.size * 100,
        --   max_updates
        -- ))
        busy_counters[queue_key] = 0
      end
    until num_processed >= max_updates or num_processed >= queue.size

    total_processed = total_processed + num_processed
    ::continue::
  end
end
]]

-------------------------------------------------------------------------------

local tick_cnt = 0
function EntityManager.on_tick()
  local now = game.tick
  local dlq = global.deadline_queue
  local entities_per_tick = 20
  local cache_table = {}

  local pcnt = 0

  for _ = 1, entities_per_tick do
    local entity_id, entity_data = DeadlineQueue.next(dlq)
    if entity_id == nil then
      break
    end

    local entity = global.entities[entity_id]

    if entity == nil or not entity.valid then
      on_entity_removed(entity_id)
    else
      local dt = handle_entity(entity, cache_table)
      if dt >= 0 then
        DeadlineQueue.queue(dlq, entity_id, entity_data, now + dt)
        entity_data._deadline_add = now
        pcnt = pcnt + 1
      else
        -- We have a valid entity that we no longer service. drop it.
        on_entity_removed(entity_id)
      end
    end
  end


  tick_cnt = tick_cnt + 1
  if tick_cnt % 60 == 0 then
    local qcnt = {}
    for idx, ents in ipairs(global.deadline_queue) do
      qcnt[idx] = table_size(ents)
    end

    print(game.tick, pcnt, serpent.line(qcnt))
  end

end

function EntityManager.on_entity_created(event)
  local entity = event.created_entity or event.destination
  if entity == nil then
    entity = event.entity
  end
  if not entity.valid then
    return
  end
  if global.forces[entity.force.name] == nil then
    return
  end
  local queue_key = manage_entity(entity, true)
  if queue_key == nil then
    return
  end
  if not entity.valid then
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

function EntityManager.on_marked_for_deconstruction(event)
  local entity = event.entity
  if entity ~= nil and entity.valid and event.player_index ~= nil then
    local player = game.players[event.player_index]
    if player ~= nil then
      Destroyer.queue_destruction(event.entity, player.force)
    end
  end
end

function EntityManager.on_marked_for_upgrade(event)
  local entity = event.entity
  if entity ~= nil and entity.valid and entity.unit_number ~= nil and event.player_index ~= nil then
    local player = game.players[event.player_index]
    if player ~= nil then
      Destroyer.queue_upgrade(event.entity, player)
    end
  end
end

return EntityManager
