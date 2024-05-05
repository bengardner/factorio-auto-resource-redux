local EntityGroups = require 'src.EntityGroups'

local super_debug = false

local function get_sprite_name(name)
  if game.item_prototypes[name] ~= nil then
    return "item/" .. name
  end
  if game.fluid_prototypes[name] ~= nil then
    return "fluid/" .. name
  end
end

local function update_player_selected(player)
  if player == nil then
    return
  end

  local gname = "MYSUPERTEST"
  local parent = player.gui.left
  local frame = parent[gname]
  if frame ~= nil then
    frame.destroy()
  end

  local info
  local entity = player.selected
  if entity ~= nil and entity.valid and entity.unit_number ~= nil then
    info = global.entity_data[entity.unit_number]
  end

  if info == nil then
    return
  end

  -- create the window/frame
  frame = parent.add {
    type = "frame",
    name = gname,
    style = "quick_bar_window_frame",
    ignored_by_interaction = true,
  }

  -- create the main vertical flow
  local vflow = frame.add {
    type = "flow",
    direction = "vertical",
  }

  -- add the header
  local hdr_frame = vflow.add {
    type = "frame",
    name = gname,
    style = "tooltip_title_frame_light",
    ignored_by_interaction = true,
  }
  local hdr_table = hdr_frame.add {
    type = "table",
    column_count = 2,
    vertical_centering = true,
  }

  local name = entity.name
  local localised_name = entity.localised_name
  local prefix = ''
  if entity.type == "entity-ghost" then
    name = entity.ghost_name
    localised_name = entity.ghost_localised_name
    prefix = 'Ghost: '
  end

  hdr_table.add {
    type="sprite",
    sprite = 'entity/' .. name,
  }
  hdr_table.add {
    type="label",
    name="MYSUPERTEST-text",
    caption = { '', prefix, localised_name, string.format(" [%s]", entity.unit_number) },
    style = "tooltip_heading_label",
  }

  -- start the description area
  local desc_flow = vflow.add {
    type = "flow",
    direction = "vertical",
  }

  if super_debug == true then
    -- debug: log info
    local xi = {}
    for k, v in pairs(info) do
      if k ~= "entity" then
        xi[k] = v
      end
    end
    desc_flow.add {
      type="label",
      caption = serpent.line(xi),
      ignored_by_interaction = true,
    }
  end

  local tt = desc_flow.add {
    type = "table",
    column_count = 2,
    vertical_centering = true,
    --style = "bordered_table"
  }

  local queue_key = EntityGroups.names_to_groups[entity.name]
  if queue_key then
    tt.add {
      type="label",
      caption = "[font=default-bold]Service type[/font]",
    }
    tt.add {
      type="label",
      caption = queue_key,
    }
  end
  if info._deadline then
    tt.add {
      type="label",
      caption = "[font=default-bold]Next Service[/font]",
    }
    tt.add {
      type="label",
      caption = string.format("%s ticks", info._deadline - game.tick),
    }
    if info._deadline_add then
      local ticks = info._deadline - info._deadline_add
      tt.add {
        type="label",
        caption = "[font=default-bold]Service Period[/font]",
      }
      tt.add {
        type="label",
        caption = string.format("%s ticks", ticks),
      }
    end
  end

--[[
  if info.service_type ~= nil then
    desc_flow.add {
      type="label",
      caption = string.format("Service type: %s", info.service_type),
      ignored_by_interaction = true,
    }
  end
  if info.service_priority ~= nil then
    desc_flow.add {
      type="label",
      caption = string.format("Service priority: %s", info.service_priority),
      ignored_by_interaction = true,
    }
  end
  if info.service_tick_delta ~= nil then
    desc_flow.add {
      type="label",
      caption = string.format("Service period: %.2f seconds", info.service_tick_delta / 60),
      ignored_by_interaction = true,
    }
  end
  if info.service_tick ~= nil then
    desc_flow.add {
      type="label",
      caption = string.format("Service tick: %s", info.service_tick),
      ignored_by_interaction = true,
    }
  end
  ]]
end


local function on_selected_entity_changed(event)
  update_player_selected(game.get_player(event.player_index))
end
script.on_event(defines.events.on_selected_entity_changed, on_selected_entity_changed)

local function update_all_players_selected()
  for _, player in pairs(game.players) do
    update_player_selected(player)
  end
end
script.on_nth_tick(7, update_all_players_selected)
