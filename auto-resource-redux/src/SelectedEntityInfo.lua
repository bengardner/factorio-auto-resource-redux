local EntityGroups = require 'src.EntityGroups'
local Util = require "src.Util"

local super_debug = true

local function ticks_to_text(ticks)
  return string.format('%s ticks (%.1f seconds)', ticks, ticks / 60)
end

local cached_status = {} -- key=value, val=name
local function entity_status_to_name(status)
  if next(cached_status) == nil then
    for k, v in pairs(defines.entity_status) do
      cached_status[v] = k
    end
  end
  return cached_status[status]
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
    caption = { '', prefix, localised_name, string.format(" [%s]", entity.unit_number) },
    style = "tooltip_heading_label",
  }

  -- start the description area
  local desc_flow = vflow.add {
    type = "flow",
    direction = "vertical",
  }

  if super_debug then
    -- debug: log info
    local xi = { unit_number = entity.unit_number }
    for k, v in pairs(info) do
      if k ~= "entity" then
        xi[k] = v
      end
    end
    if global.player_selected_unum == nil then
      global.player_selected_unum = {}
    end
    local pxi = global.player_selected_unum[player.index] or {}
    if not Util.same_value(pxi, xi) then
      global.player_selected_unum[player.index] = xi
      log(serpent.block(xi))
    end
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
      caption = ticks_to_text(info._deadline - game.tick),
    }
    if info._deadline_add then
      local ticks = info._deadline - info._deadline_add
      tt.add {
        type="label",
        caption = "[font=default-bold]Desired Period[/font]",
      }
      tt.add {
        type="label",
        caption = ticks_to_text(ticks),
      }
    end
    if info._service_period ~= nil then
      tt.add {
        type="label",
        caption = "[font=default-bold]Last Period[/font]",
      }
      tt.add {
        type="label",
        caption = ticks_to_text(info._service_period),
      }
    end
    if info._service_period ~= nil then
      tt.add {
        type="label",
        caption = "[font=default-bold]Status[/font]",
      }
      tt.add {
        type="label",
        caption = string.format("%s %s", entity.status, entity_status_to_name(entity.status)),
      }
    end
  end
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
