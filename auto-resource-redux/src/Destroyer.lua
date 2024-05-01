local Destroyer = {}

local Storage = require "src.Storage"

function Destroyer.initialise()
  if global.destroyer == nil then
    global.destroyer = { cliff_queue={}, mine_queue={}, upgrade_queue={}, seqno=0 }
  end
end

-- get a key or virtual key for an entity
local function get_mine_key(entity)
  local key = entity.unit_number
  if key == nil then
    local seqno = (global.destroyer.seqno or 0) + 1
    if seqno > 2000000000 then
      seqno = 0
    end
    global.destroyer.seqno = seqno
    key = -seqno
  end
  return key
end

-- queue the entity for destruction in a few seconds
function Destroyer.queue_destruction(entity, force)

  local qq

  if entity.type == "cliff" and entity.prototype.cliff_explosive_prototype ~= nil then
    qq = global.destroyer.cliff_queue

  elseif entity.prototype.mineable_properties ~= nil and entity.prototype.mineable_properties.minable == true then
    qq = global.destroyer.mine_queue

  else
    log(("Destroyer: don't know what to do with %s %s"):format(entity.name, entity.type))
      return
  end
  log(("queue_destruction: %s %s @ %s force=%s by force=%s"):format(entity.name, entity.type, serpent.line(entity.position),
    entity.force.name, force.name))

  -- The entity has already been marked for destruction, so it must be OK. Right?
  qq[get_mine_key(entity)] = { entity, game.tick + 30, force }
end

function Destroyer.process_mine_queue()
  local qq = global.destroyer.mine_queue
  local now = game.tick
  local inv
  local left = 1000

  for key, val in pairs(qq) do
    local ent = val[1]
    if ent.valid and ent.to_be_deconstructed() then
      if now >= val[2] then
        local force = val[3]
        local storage = Storage.get_storage_for_force(ent, force.name)
        if inv == nil then
          inv = game.create_inventory(100)
        end
        --log(("mine: %s %s @ %s"):format(ent.name, ent.type, serpent.line(ent.position)))
        if ent.mine({ inventory=inv }) then
          qq[key] = nil
          Storage.add_from_inventory(storage, inv, true)
          left = left - 1
          if left <= 0 then
            break
          end
        end
      end
    else
      -- either not valid or no longer marked for destruction
      qq[key] = nil
    end
  end
  if inv ~= nil then
    inv.destroy()
  end
end

--[[
global.mod.mine_queue contains items that are waiting to be mined.
This steps through them and mines up to 1000 of them in one go.
]]
function Destroyer.process_cliff_queue()
  local qq = global.destroyer.cliff_queue
  local now = game.tick

  -- try killing cliffs, one per cycle
  for key, val in pairs(qq) do
    local ent = val[1]
    if ent.valid and ent.to_be_deconstructed() then
      if now >= val[2] then
        local exp_name = ent.prototype.cliff_explosive_prototype
        if exp_name ~= nil then
          local force = val[3]
          if force == nil then
            qq[key] = nil
          else
            local storage = Storage.get_storage_for_force(ent, force.name)
            local xxx = Storage.remove_item(storage, exp_name, 1, true)
            if xxx > 0 then
              log(("blasting cliff with %s @ %s"):format(exp_name, serpent.line(ent.position)))
              ent.surface.create_entity({
                name=exp_name,
                position=ent.position,
                force=ent.force,
                target=ent.position,
                speed=1})
              break
            end
          end
        else
          val[2] = now + 180
        end
      end
    else
      -- no longer scheduled for deletion or already gone
      qq[key] = nil
    end
  end
end

function Destroyer.queue_upgrade(entity, player)
  local qq = global.destroyer.upgrade_queue
  if qq == nil then
    qq = {}
    global.destroyer.upgrade_queue = qq
  end

  qq[entity.unit_number] = { entity, game.tick + 30, player }
end

--[[
global.mod.mine_queue contains items that are waiting to be mined.
This steps through them and mines up to 1000 of them in one go.
]]
function Destroyer.process_upgrade_queue()
  local do_now = {}
  local do_later = {}
  local now = game.tick

  -- filter all the pending upgrades based on what is ready to go
  for unum, val in pairs(global.destroyer.upgrade_queue or {}) do
    local entity = val[1]
    -- has to be valid and still marked for upgrade
    if entity.valid and entity.to_be_upgraded() then
      -- and it has to be time
      if now >= val[2] then
        do_now[unum] = val
      else
        do_later[unum] = val
      end
    end
  end

  for unum, val in pairs(do_now) do
    local entity = val[1]
    local player = val[3]
    local upgrade_prot = entity.get_upgrade_target()
    if upgrade_prot == nil then
      goto drop_and_continue
    end

    local storage = Storage.get_storage(entity)
    local n_avail = Storage.get_available_item_count(storage, upgrade_prot.name, 1, false)
    if n_avail > 0 then
      local dir = entity.get_upgrade_direction()
      if dir == nil then
        dir = entity.direction
      end
      local old_name = entity.name

      local new_ent = entity.surface.create_entity({
        name = upgrade_prot.name,
        position = entity.position,
        direction = dir,
        force = entity.force,
        fast_replace = true,
        player = player, -- need a player or it drops on the ground!
        spill = true,
        raise_built = true,
        create_build_effect_smoke = true,
      })
      if new_ent ~= nil then
        Storage.remove_item(storage, upgrade_prot.name, 1, true)
        log(("Upgraded %s to %s @ %s"):format(old_name, new_ent.name, serpent.line(new_ent.position)))
      end
    else
      -- no items available. try again in a few seconds
      -- print(string.format("cannot upgrade %s @ %s", ent.name, serpent.line(ent.position)))
      val[2] = now + 180
      do_later[unum] = val
    end
    ::drop_and_continue::
  end
  global.destroyer.upgrade_queue = do_later
end

function Destroyer.on_tick()
  local cycle = game.tick % 60
  if cycle == 0 then
    Destroyer.process_mine_queue()
  elseif cycle == 20 then
    Destroyer.process_cliff_queue()
  elseif cycle == 40 then
    Destroyer.process_upgrade_queue()
  end
end

return Destroyer
