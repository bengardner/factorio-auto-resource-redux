local GUIResourceList = {}

local flib_table = require("__flib__/table")
local GUICommon = require "src.GUICommon"
local GUIDispatcher = require "src.GUIDispatcher"
local GUILimitDialog = require "src.GUILimitDialog"
local R = require "src.RichText"
local Storage = require "src.Storage"
local Util = require "src.Util"


local OLD_GUI_RESOURCE_TABLE = "arr-table"
-- used to check if the resource table needs to be recreated
local RESOURCE_TABLE_VERSION = 1
local TICKS_PER_UPDATE = 12
local RES_BUTTON_EVENT = "arr-res-btn"
-- { [storage_key] = order int }
local storage_keys_order = {}
-- { [storage_key] = group str }
local storage_keys_groups = {}
-- { [group_str] = order int }
local storage_keys_group_order = {}

local function find_gui_index_for(parent, ordering, element_name)
  for i, child in ipairs(parent.children) do
    if ordering[child.name] > ordering[element_name] then
      return i
    end
  end
  return nil
end

function GUIResourceList.get_or_create_button(player, storage_key)
  local gui_top = player.gui.top
  local table_flow = gui_top[GUICommon.GUI_RESOURCE_TABLE] or gui_top.add({
    type = "flow",
    direction = "vertical",
    name = GUICommon.GUI_RESOURCE_TABLE,
    tags = { version = RESOURCE_TABLE_VERSION }
  })

  local group_name = storage_keys_groups[storage_key]
  local table_elem = table_flow[group_name] or table_flow.add({
    type = "table",
    column_count = 20,
    name = group_name,
    index = find_gui_index_for(table_flow, storage_keys_group_order, group_name),
    style = "logistics_slot_table"
  })

  local button = table_elem[storage_key] or GUICommon.create_item_button(
    table_elem,
    storage_key,
    {
      name = storage_key,
      tags = { event = RES_BUTTON_EVENT, item = storage_key, flash_anim = 0 },
      mouse_button_filter = { "left", "right", "middle" },
      index = find_gui_index_for(table_elem, storage_keys_order, storage_key)
    }
  )
  return button, group_name
end

GUICommon.get_or_create_reslist_button = GUIResourceList.get_or_create_button

local function update_gui(player)
  local storage = Storage.get_storage(player)

  local gui_top = player.gui.top
  local old_table = gui_top[OLD_GUI_RESOURCE_TABLE]
  if old_table then
    old_table.destroy()
  end
  old_table = gui_top[GUICommon.GUI_RESOURCE_TABLE]
  if old_table and old_table.tags.version ~= RESOURCE_TABLE_VERSION then
    old_table.destroy()
  end

  local table_flow = gui_top[GUICommon.GUI_RESOURCE_TABLE]
  if table_flow and not table_flow.visible then
    return
  end

  local expected_buttons = {}
  for storage_key, count in pairs(storage.items) do
    local button, group_name = GUIResourceList.get_or_create_button(player, storage_key)
    expected_buttons[group_name .. ";" .. button.name] = true
    local fluid_name = Storage.unpack_fluid_item_name(storage_key)

    local num_vals, sum, min, max
    if fluid_name then
      num_vals, sum, min, max = Util.table_val_stats(count)
    end

    local quantity = min or count
    local item_limit = Storage.get_item_limit(storage, storage_key) or 0
    local reserved = Storage.get_item_reservation(storage, storage_key)
    local is_red = quantity <= (reserved > 0 and reserved or item_limit * 0.01)
    local tooltip = {
      "", R.FONT_BOLD, R.COLOUR_LABEL,
      fluid_name and { "fluid-name." .. fluid_name } or game.item_prototypes[storage_key].localised_name,
      R.COLOUR_END,
      "\n",
      (is_red and R.COLOUR_RED or ""), (min or count), (is_red and R.COLOUR_END or ""),
      "/", item_limit,
      R.FONT_END,
      reserved > 0 and ("\n[color=#e6d0ae][font=default-bold]Reserved:[/font][/color] " .. reserved) or ""
    }
    -- List the levels of each fluid temperature
    if fluid_name then
      if num_vals > 1 then
        Util.array_extend(
          tooltip,
          { "\n", R.LABEL, { "gui.total" }, R.LABEL_END, ": ", sum }
        )
      end
      local i = 0
      local qty_strs = {}
      local wrap = math.max(1, math.floor(num_vals / 10))
      for temperature, qty in pairs(count) do
        local colour_tag = nil
        if is_red and qty == min then
          colour_tag = R.COLOUR_RED
        elseif qty == max then
          colour_tag = R.COLOUR_GREEN
        end
        table.insert(
          qty_strs,
          string.format(
            "%s[color=#e6d0ae][font=default-bold]%d°C:[/font][/color] %s%d%s",
            i % wrap == 0 and "\n" or ", ",
            temperature,
            colour_tag and colour_tag or "",
            qty,
            colour_tag and "[/color]" or ""
          )
        )
        i = i + 1
      end
      table.insert(tooltip, table.concat(qty_strs))
    end
    if button.tags.flash_anim <= 3 then
      button.toggled = button.tags.flash_anim % 2 == 0
      local tags = button.tags
      tags.flash_anim = tags.flash_anim + 1
      button.tags = tags
    end
    button.number = quantity
    button.tooltip = tooltip
    button.style = is_red and "red_slot_button" or "slot_button"
  end

  -- remove unexpected buttons
  if not table_flow then
    return
  end
  for _, table_name in ipairs(table_flow.children_names) do
    local table_elem = table_flow[table_name]
    for _, button_name in ipairs(table_elem.children_names) do
      if not expected_buttons[table_name .. ";" .. button_name] then
        table_elem[button_name].destroy()
      end
    end
  end
end

function GUIResourceList.on_tick()
  local _, player = Util.get_next_updatable("resource_gui", TICKS_PER_UPDATE, game.connected_players)
  if player then
    update_gui(player)
  end
end

function GUIResourceList.initialise()
  storage_keys_order = {}
  for item_name, item in pairs(game.item_prototypes) do
    table.insert(storage_keys_order, item_name)
  end
  for fluid_name, item in pairs(game.fluid_prototypes) do
    local storage_key = Storage.get_fluid_storage_key(fluid_name)
    table.insert(storage_keys_order, storage_key)
  end
  table.sort(
    storage_keys_order,
    Util.prototype_order_comp_fn(
      function(key)
        local fluid_name = Storage.unpack_fluid_item_name(key)
        return fluid_name and game.fluid_prototypes[fluid_name] or game.item_prototypes[key]
      end
    )
  )

  storage_keys_groups = {}
  storage_keys_group_order = {}
  for i, storage_key in ipairs(storage_keys_order) do
    local fluid_name = Storage.unpack_fluid_item_name(storage_key)
    local proto = fluid_name and game.fluid_prototypes[fluid_name] or game.item_prototypes[storage_key]

    storage_keys_groups[storage_key] = proto.group.name
    if storage_keys_group_order[proto.group.name] == nil then
      storage_keys_group_order[proto.group.name] = true
    end
  end

  storage_keys_order = flib_table.invert(storage_keys_order)
  storage_keys_group_order = flib_table.invert(Util.table_keys(storage_keys_group_order))
end

local function on_button_clicked(event, tags, player)
  local storage_key = tags.item
  local click_str = GUICommon.get_click_str(event)

  if click_str == "middle" then
    GUILimitDialog.open(player, storage_key, event.cursor_display_location)
    return
  end

  -- click to take, or right click to clear (if 0)
  local storage = Storage.get_storage(player)
  local is_fluid = Storage.unpack_fluid_item_name(storage_key)
  if click_str == "right" and is_fluid then
    storage.items[storage_key] = Util.table_filter(
      storage.items[storage_key],
      function(k, v)
        return v >= 1
      end
    )
  end
  if click_str == "right" and (
        storage.items[storage_key] == 0
        or (is_fluid and table_size(storage.items[storage_key]) == 0)
      ) then
    event.element.destroy()
    storage.items[storage_key] = nil
    return
  end
  if is_fluid then
    return
  end
  local stored_count = storage.items[storage_key] or 0
  local stack_size = (game.item_prototypes[storage_key] or {}).stack_size or 50
  local amount_to_give = ({
    ["left"] = 1,
    ["right"] = 5,
    ["shift-left"] = stack_size,
    ["shift-right"] = math.ceil(stack_size / 2),
    ["control-left"] = stored_count,
    ["control-right"] = math.ceil(stored_count / 2),
  })[click_str] or 0
  amount_to_give = Util.clamp(amount_to_give, 0, stored_count)
  if amount_to_give <= 0 then
    return
  end
  local cursor_cleared = player.clear_cursor()

  local inventory = player.get_inventory(defines.inventory.character_main)
  if not inventory then
    return
  end
  local amount_given = Storage.put_in_inventory(storage, inventory, storage_key, amount_to_give, true)
  update_gui(player)

  local item_proto = game.item_prototypes[storage_key]
  if amount_given <= 0 then
    player.print({
      "inventory-restriction.player-inventory-full",
      item_proto.localised_name,
      { "inventory-full-message.main" }
    })
  end

  -- TODO: change this to only place in cursor when the player pipettes (q)
  local placeable = item_proto.place_result or item_proto.place_as_equipment_result or item_proto.place_as_tile_result
  if cursor_cleared and placeable then
    local stack = inventory.find_item_stack(storage_key)
    local cursor = player.cursor_stack
    if cursor and stack and stack.valid_for_read then
      cursor.transfer_stack(stack)
    end
  end
end

function GUIResourceList.on_player_changed_surface(event)
  local player = game.get_player(event.player_index)
  update_gui(player)
end

GUIDispatcher.register(defines.events.on_gui_click, RES_BUTTON_EVENT, on_button_clicked)

function GUIResourceList.toggle_display(player)
  local gui_top = player.gui.top
  local table_flow = gui_top[GUICommon.GUI_RESOURCE_TABLE]
  if table_flow ~= nil then
    table_flow.visible = not table_flow.visible
    update_gui(player)
  end
end

return GUIResourceList
