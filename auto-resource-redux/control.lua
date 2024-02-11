if script.active_mods["gvv"] then require("__gvv__.gvv")() end

local Util = require("src.Util")
local DomainStore = require "src.DomainStore";
local EntityGroups = require "src.EntityGroups";
local Storage = require "src.Storage"
local EntityCustomData = require "src.EntityCustomData"
local EntityManager = require "src.EntityManager"
local LogisticManager = require("src.LogisticManager")
local ItemPriorityManager = require "src.ItemPriorityManager"
local GUIResourceList = require "src.GUIResourceList"
local GUIModButton = require "src.GUIModButton"
local GUIRequesterTank = require "src.GUIRequesterTank"
local GUIDispatcher = require "src.GUIDispatcher"


local initialised = false

local function initialise()
  -- automatically enable processing the player force
  if global.forces == nil then
    global.forces = { player = true }
  end

  DomainStore.initialise()
  EntityGroups.initialise()
  ItemPriorityManager.initialise()
  Storage.initialise()
  EntityCustomData.initialise()
  EntityManager.initialise()
  LogisticManager.initialise()
  GUIResourceList.initialise()
end

local function on_tick()
  if not initialised then
    initialised = true
    initialise()
  end

  EntityManager.on_tick()
  LogisticManager.on_tick()
  GUIModButton.on_tick()
  GUIResourceList.on_tick()
end

local function on_built(event)
  EntityManager.on_entity_created(event)
  EntityCustomData.on_built(event)
end

local function on_cloned(event)
  EntityManager.on_entity_created(event)
  EntityCustomData.on_cloned(event)
end

script.on_nth_tick(1, on_tick)

-- create
script.on_event(defines.events.on_built_entity, on_built)
script.on_event(defines.events.on_robot_built_entity, on_built)
script.on_event(defines.events.script_raised_revive, on_built)
script.on_event(defines.events.on_entity_cloned, on_cloned)
script.on_event(defines.events.script_raised_built, EntityManager.on_entity_created)

-- delete
script.on_event(defines.events.on_pre_player_mined_item, EntityManager.on_entity_removed)
script.on_event(defines.events.on_robot_mined_entity, EntityManager.on_entity_removed)
script.on_event(defines.events.script_raised_destroy, EntityManager.on_entity_removed)
script.on_event(defines.events.on_entity_died, EntityManager.on_entity_died)

-- gui
script.on_event(defines.events.on_gui_click, GUIDispatcher.on_event)
script.on_event(defines.events.on_gui_closed, GUIDispatcher.on_event)
script.on_event(defines.events.on_gui_value_changed, GUIDispatcher.on_event)
script.on_event(defines.events.on_gui_text_changed, GUIDispatcher.on_event)
script.on_event(defines.events.on_gui_elem_changed, GUIDispatcher.on_event)
script.on_event(defines.events.on_gui_checked_state_changed, GUIDispatcher.on_event)
script.on_event(GUIDispatcher.ON_CONFIRM_KEYPRESS, GUIDispatcher.on_event)
script.on_event(defines.events.on_gui_confirmed, GUIDispatcher.on_event)
script.on_event(defines.events.on_gui_opened, GUIDispatcher.on_event)

-- blueprint/settings
script.on_event(defines.events.on_player_setup_blueprint, EntityCustomData.on_setup_blueprint)