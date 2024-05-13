local EntityGroups = {}

-- mapping of entity names to our "group" for them
EntityGroups.names_to_groups = {}

-- Ordered list: later filters override earlier filters
EntityGroups.entity_group_filters = {
  { "car",  { filter = "type", type = "car" }},
  { "boiler", { filter = "type", type = "boiler" }},
  { "burner-generator", { filter = "type", type = "burner-generator" }},
  { "furnace", { filter = "type", type = "furnace" }},
  { "mining-drill", { filter = "type", type = "mining-drill" }},
  { "artillery-turret", { filter = "type", type = "artillery-turret" }},
  { "ammo-turret", { filter = "type", type = "ammo-turret" }},
  { "assembling-machine", { filter = "type", type = "assembling-machine" }},
  { "lab", { filter = "type", type = "lab" }},
  { "sink-chest",{ filter = "name", name = "arr-hidden-sink-chest" }},
  { "sink-tank",{ filter = "name", name = "arr-sink-tank" }},
  { "logistic-sink-chest",{ filter = "name", name = "arr-logistic-sink-chest" }},
  { "logistic-requester-chest",{ filter = "name", name = "arr-logistic-requester-chest" }},
  { "arr-requester-tank",{ filter = "name", name = "arr-requester-tank" }},
  { "spidertron",{ filter = "type", type = "spider-vehicle" }},
  { "reactor", { filter = "type", type = "reactor" }},
  { "rocket-silo", { filter = "type", type = "rocket-silo" }},
  { "arr-combinator", { filter = "name", name = "arr-combinator" }},
  { "entity-ghost", { filter = "type", type = "entity-ghost" }},
  { "tile-ghost", { filter = "type", type = "tile-ghost" }},
}

function EntityGroups.calculate_groups()
  EntityGroups.names_to_groups = {}
  for _, info in ipairs(EntityGroups.entity_group_filters) do
    local group_name = info[1]
    local prototype_filter = info[2]
    local entity_prototypes = game.get_filtered_entity_prototypes({ prototype_filter })
    for name, prototype in pairs(entity_prototypes) do
      EntityGroups.names_to_groups[name] = group_name
    end
  end
end

function EntityGroups.can_manage(entity)
  return EntityGroups.names_to_groups[entity.name] ~= nil
end

function EntityGroups.initialise()
  EntityGroups.calculate_groups()
end

return EntityGroups
