--
-- This file is based on Alpha 10's stonehearth/services/server/inventory/inventory_service.lua
--

local Entity = _radiant.om.Entity
local Inventory = require 'services.server.inventory.inventory'
local InventoryService = class()

function InventoryService:__init()
end

function InventoryService:initialize()
  self._sv = self.__saved_variables:get_data()

  if not self._sv.inventories then
    self._sv.inventories = {}

  end

  self:_register_score_functions()

  -- TODO: Find a better way to hook this up. Somehow?
  radiant.events.listen_once(radiant, 'stonehearth:gameloop', self, self._install_traces)

  -- entity_id => outvetory:storage
  self._storages = {}
  -- entity_id => entity. List of entities that could not be put into a storage yet.
  self._queue = {}
end

function InventoryService:add_inventory(player_id)
  radiant.check.is_string(player_id)
  assert(not self._sv.inventories[player_id])
  local inventory = radiant.create_controller('stonehearth:inventory', player_id)
  assert(inventory)
  self._sv.inventories[player_id] = inventory
  self.__saved_variables:mark_changed()
  return inventory
end

function InventoryService:get_inventory(arg1)
  local player_id

  if radiant.util.is_a(arg1, 'string') then
    player_id = arg1
  elseif radiant.util.is_a(arg1, Entity) then
    player_id = radiant.entities.get_player_id(arg1)
  else
    error(string.format('unexpected value %s in get_inventory', radiant.util.tostring(player_id)))
  end

  radiant.check.is_string(player_id)
  if self._sv.inventories[player_id] then
    return self._sv.inventories[player_id]
  end
end

function InventoryService:get_item_tracker_command(session, response, tracker_name)
  local inventory = self:get_inventory(session.player_id)

  if inventory == nil then
    response:reject('there is no inventory for player ' .. session.player_id)
    return
  end

  return {
    tracker = inventory:get_item_tracker(tracker_name),
  }

end

function InventoryService:_register_score_functions()
  stonehearth.score:add_aggregate_eval_function('net_worth', 'buildings', function(entity, agg_score_bag)
      if entity:get_component 'stonehearth:construction_data' then
        agg_score_bag.buildings = agg_score_bag.buildings + self:_get_score_for_building(entity)
      end
    end)
  stonehearth.score:add_aggregate_eval_function('net_worth', 'placed_item', function(entity, agg_score_bag)
      if entity:get_component 'stonehearth:entity_forms' then
        local item_value = stonehearth.score:get_score_for_entity(entity)
        agg_score_bag.placed_item = agg_score_bag.placed_item + item_value
      end
    end)
  stonehearth.score:add_aggregate_eval_function('net_worth', 'stocked_resources', function(entity, agg_score_bag)
      if entity:get_component 'stonehearth:stockpile' then
        agg_score_bag.stocked_resources = agg_score_bag.stocked_resources + self:_get_score_for_stockpile(entity)
      end
    end)
  stonehearth.score:add_aggregate_eval_function('resources', 'edibles', function(entity, agg_score_bag)
      if entity:get_component 'stonehearth:stockpile' then
        local stockpile_component = entity:get_component 'stonehearth:stockpile'
        local items = stockpile_component:get_items()
        local total_score = 0

        for id, item in pairs(items) do
          if radiant.entities.is_material(item, 'food_container') or radiant.entities.is_material(item, 'food') then
            local item_value = stonehearth.score:get_score_for_entity(item)
            agg_score_bag.edibles = agg_score_bag.edibles + item_value
          end
        end
      end
    end)
end

function InventoryService:_get_score_for_building(entity)
  local region = entity:get_component 'destination':get_region()
  local area = region:get():get_area()
  local item_multiplier = stonehearth.score:get_score_for_entity(entity)

  return (area * item_multiplier)^0.5
end

function InventoryService:_get_score_for_stockpile(entity)
  local stockpile_component = entity:get_component 'stonehearth:stockpile'
  local items = stockpile_component:get_items()
  local total_score = 0

  for id, item in pairs(items) do
    local item_value = stonehearth.score:get_score_for_entity(item)
    total_score = total_score + item_value
  end

  return total_score / 10
end

function InventoryService:_install_traces()
  local ec = radiant.entities.get_root_entity():get_component 'entity_container'
  self._ec_trace = ec:trace_children('tracking inventory service'):on_added(function(id, entity)
      self:_add_item(entity)
    end):on_removed(function(id, entity)
      self:_remove_item(id)
    end)

  self._destroy_listener = radiant.events.listen(radiant, 'radiant:entity:post_destroy', self, self._on_item_destroyed)
end

-- Callback; whenever an item is added to the world.
function InventoryService:_add_item(entity)
  -- Try it in every storage we have
  for entity_id, storage in pairs(self._storages) do
    if storage:can_accept(entity) then
      printf('send %s to %s', tostring(entity), tostring(storage._entity))
      error('NYI')
      return
     end
  end

  -- Unable to process the entity at this time, add it to the queue
  printf('unable to store %s; added to queue', tostring(entity))
  self._queue[entity:get_id()] = entity
end

-- Callback; whenever an item is removed from the world.
function InventoryService:_remove_item(entity)
  print('removed entity:', entity)
  self._queue[entity:get_id()] = nil
end

function InventoryService:_on_item_destroyed(entity_id) -- TODO: naming
  print('destroyed:', entity_id)
  self._queue[entity_id] = nil
end

-- Callback; whenever a storage is added to the world.
function InventoryService:add_storage(storage)
  self._storages[storage:get_id()] = storage:get_component('outvetory:storage')
end

-- Callback; whenever a storage is removed from the world.
function InventoryService:remove_storage(storage)
  self._storages[storage:get_id()] = nil
end

return InventoryService
