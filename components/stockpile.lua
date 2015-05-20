--
-- This file is based on Alpha 10's stonehearth/components/stockpile/stockpile_component.lua
--

local priorities = require 'constants'.priorities.worker_task
local StockpileComponent = class()
StockpileComponent.__classname = 'StockpileComponent'
local log = radiant.log.create_logger 'stockpile'
local Cube3 = _radiant.csg.Cube3
local Point2 = _radiant.csg.Point2
local Point3 = _radiant.csg.Point3
local Region3 = _radiant.csg.Region3
local all_stockpiles = {}

local ALL_FILTER_FNS = {}

local function _can_stock_entity (entity, filter)
  if not entity or not entity:is_valid() then
    log:spam('%s is not a valid entity.  cannot be stocked.', tostring(entity))
    return false
  end

  local efc = entity:get_component 'stonehearth:entity_forms'

  if efc and efc:get_should_restock() then
    local iconic = efc:get_iconic_entity()

    return _can_stock_entity(iconic, filter)
  end

  if not entity:get_component 'item' then
    log:spam('%s is not an item material.  cannot be stocked.', entity)
    return false
  end

  local material = entity:get_component 'stonehearth:material'

  if not material then
    log:spam('%s has no material.  cannot be stocked.', entity)
    return false
  end

  if not filter then
    log:spam('stockpile has no filter.  %s item can be stocked!', entity)
    return true
  end

  for i, mat in ipairs(filter) do
    if material:is(mat) then
      log:spam('%s matches filter "%s" and can be stocked!', entity, mat)
      return true
    end
  end

  log:spam('%s failed filter.  cannot be stocked.', entity)
  return false
end

function get_stockpile_containing_entity(entity)
  local location = radiant.entities.get_world_grid_location(entity)

  if location then
    for id, stockpile in pairs(all_stockpiles) do
      if stockpile then
        local name = tostring(stockpile:get_entity())
        local bounds = stockpile:get_bounds()
        log:spam('checking to see if %s (pos:%s) is inside a %s', entity, location, name)
        if not bounds:contains(location) then
          log:spam('  %s -> nope! wrong bounds, %s', name, bounds)
        elseif not stockpile:can_stock_entity(entity) then
          log:spam('  %s -> nope! cannot stock', name)
        else
          log:spam('  %s -> yup!', name)
          return stockpile
        end
      end
    end
  end
end

function StockpileComponent:initialize(entity, json)
  self._entity = entity
  self._sv = self.__saved_variables:get_data()

  if not self._sv.stocked_items then
    self._sv.active = true
    self._sv.size = Point2(0, 0)
    self._sv.stocked_items = {}

    self._sv.item_locations = {}

    self._sv.player_id = nil
    self:_assign_to_player()
    self._sv._filter_key = 'stockpile nofilter+' .. self._sv.player_id
    self._destination = entity:add_component 'destination'
    self._destination:set_region(_radiant.sim.alloc_region3()):set_reserved(_radiant.sim.alloc_region3()):set_auto_update_adjacent(true)
    self:_install_traces()
  else
    self._destination = entity:get_component 'destination'
    self._destination:set_reserved(_radiant.sim.alloc_region3())
    self:_create_worker_tasks()
    radiant.events.listen_once(radiant, 'radiant:game_loaded', function(e)
        self:_install_traces()
      end)
  end

  all_stockpiles[self._entity:get_id()] = self
end

function StockpileComponent:get_entity()
  return self._entity
end

function StockpileComponent:destroy()
  log:info('%s destroying stockpile component', self._entity)
  all_stockpiles[self._entity:get_id()] = nil

  for id, item in pairs(self._sv.stocked_items) do
    self:_remove_item_from_stock(id)
  end

  local player_id = self._entity:add_component 'unit_info':get_player_id()
  stonehearth.inventory:get_inventory(player_id):remove_stockpile(self._entity)
  if self._ec_trace then
    self._ec_trace:destroy()
    self._ec_trace = nil
  end

  if self._unit_info_trace then
    self._unit_info_trace:destroy()
    self._unit_info_trace = nil
  end

  if self._mob_trace then
    self._mob_trace:destroy()
    self._mob_trace = nil
  end

  if self._destroy_listener then
    self._destroy_listener:destroy()
    self._destroy_listener = nil
  end

  self:_destroy_tasks()
end

local function get_restock_filter_fn (filter_key, filter, player_id)
  local filter_fn = ALL_FILTER_FNS[filter_key]

  if not filter_fn then
    local captured_filter

    if filter then
      captured_filter = {}

      for _, material in ipairs(filter) do
        table.insert(captured_filter, material)
      end
    end

    function filter_fn(item)
      log:detail('calling filter function on %s', item)
      local containing_component = get_stockpile_containing_entity(item)
      local containing_entity = containing_component and containing_component:get_entity()
      local item_player_id = radiant.entities.get_player_id(item)

      if item_player_id ~= player_id then
        log:detail('item player id "%s" ~= stockpile id "%s".  returning from filter function', item_player_id, player_id)
        return false
      end

      if containing_entity then
        if stonehearth.game_master:is_enabled() then
          log:detail 'already stocked!  returning false from filter function'
          return false
        end

        local containing_stockpile_owner_id = radiant.entities.get_player_id(containing_entity)
        log:detail('item:      %s', radiant.entities.get_player_id(item))
        log:detail('stockpile: %s', containing_stockpile_owner_id)
        local already_stocked = not radiant.entities.are_players_hostile(player_id, containing_stockpile_owner_id)

        if already_stocked then
          log:detail 'already stocked!  returning false from filter function'
          return false
        else
          log:detail 'item in stockpile, but not one of ours.'
        end
      end

      return _can_stock_entity(item, captured_filter)
    end


    ALL_FILTER_FNS[filter_key] = filter_fn
  end

  return filter_fn
end

function StockpileComponent:get_filter()
  return get_restock_filter_fn(self._sv._filter_key, self._sv.filter, self._sv.player_id)
end

function StockpileComponent:set_filter(filter)
  self._sv.filter = filter

  if self._sv.filter then
    self._sv._filter_key = 'stockpile filter:'
    table.sort(self._sv.filter)
    for _, material in ipairs(self._sv.filter) do
      self._sv._filter_key = self._sv._filter_key .. '+' .. material
    end
  else
    self._sv._filter_key = 'stockpile nofilter'
  end

  self._sv._filter_key = self._sv._filter_key .. '+' .. self._sv.player_id
  self.__saved_variables:mark_changed()
  for id, location in pairs(self._sv.item_locations) do
    local item = radiant.entities.get_entity(id)
    local can_stock = self:can_stock_entity(item)
    local is_stocked = self._sv.stocked_items[id] ~= nil

    if can_stock and not is_stocked then
      self:_add_item_to_stock(item)
    end

    if not can_stock and is_stocked then
      self:_remove_item_from_stock(item:get_id())
    end
  end

  self:_create_worker_tasks()
  radiant.events.trigger_async(self._entity, 'stonehearth:stockpile:filter_changed')
  return self
end

function StockpileComponent:_install_traces()
  local ec = radiant.entities.get_root_entity():get_component 'entity_container'
  self._ec_trace = ec:trace_children 'tracking stockpile':on_added(function(id, entity)
      self:_add_item(entity)
    end):on_removed(function(id, entity)
      self:_remove_item(id)
    end)
  local mob = self._entity:add_component 'mob'
  self._mob_trace = mob:trace_transform 'stockpile tracking self position':on_changed(function()
      self:_rebuild_item_sv()
    end)
  local unit_info = self._entity:add_component 'unit_info'
  self._unit_info_trace = unit_info:trace_player_id 'stockpile tracking player_id':on_changed(function()
      self:_assign_to_player()
    end)
  self._destroy_listener = radiant.events.listen(radiant, 'radiant:entity:post_destroy', self, self._on_item_destroyed)
end

function StockpileComponent:get_items()
  return self._sv.stocked_items
end

function StockpileComponent:_get_bounds()
  local size = self:get_size()
  local bounds = Cube3(Point3(0, 0, 0), Point3(size.x, 1, size.y))

  return bounds
end

function StockpileComponent:get_bounds()
  local size = self:get_size()
  local origin = radiant.entities.get_world_grid_location(self._entity)

  if not origin then
    return nil
  end

  local bounds = Cube3(origin, Point3(origin.x + size.x, origin.y + 1, origin.z + size.y))

  return bounds
end

function StockpileComponent:is_full()
  if self._destination and self._destination:is_valid() then
    return self._destination:get_region():get():empty()
  end

  return true
end

function StockpileComponent:bounds_contain(item_entity)
  local location = radiant.entities.get_world_grid_location(item_entity)
  local world_bounds = self:get_bounds()

  if not world_bounds then
    return false
  end

  return world_bounds:contains(location)
end

function StockpileComponent:get_size()
  return self._sv.size
end

function StockpileComponent:set_size(x, y)
  self._sv.size = Point2(x, y)
  self:_rebuild_item_sv()
  self:_create_worker_tasks()
end

function StockpileComponent:notify_restock_finished(location)
  if self._entity:is_valid() then
    self:_add_to_region(location)
  end
end

function StockpileComponent:_add_to_region(location)
  log:debug('adding point %s to region', tostring(location))
  local offset = location - radiant.entities.get_world_grid_location(self._entity)
  local was_full = self:is_full()
  self._destination:get_region():modify(function(cursor)
      cursor:subtract_point(offset)
    end)
  if not was_full and self:is_full() then
    radiant.events.trigger(self._entity, 'stonehearth:stockpile:space_available', self, false)
  end
end

function StockpileComponent:_remove_from_region(location)
  log:debug('removing point %s from region', tostring(location))
  local offset = location - radiant.entities.get_world_grid_location(self._entity)
  local was_full = self:is_full()
  self._destination:get_region():modify(function(cursor)
      cursor:add_point(offset)
    end)
  if was_full and not self:is_full() then
    radiant.events.trigger(self._entity, 'stonehearth:stockpile:space_available', self, true)
  end
end

function StockpileComponent:_add_item(entity)
  if self:bounds_contain(entity) and entity:get_component 'item' then
    local location = radiant.entities.get_world_grid_location(entity)
    self:_add_to_region(location)
    if self:can_stock_entity(entity) then
      log:debug('adding %s to stock', entity)
      self:_add_item_to_stock(entity)
    end
  end
end

function StockpileComponent:_add_item_to_stock(entity)
  assert(self:can_stock_entity(entity) and self:bounds_contain(entity))
  local location = radiant.entities.get_world_grid_location(entity)

  for id, existing in pairs(self._sv.stocked_items) do
    if radiant.entities.get_world_grid_location(existing) == location then
      log:error('putting %s on top of existing item %s in stockpile (location:%s)', entity, existing, location)
    end
  end

  local id = entity:get_id()
  self._sv.item_locations[id] = location
  self._sv.stocked_items[id] = entity
  self.__saved_variables:mark_changed()
  stonehearth.inventory:get_inventory(self._sv.player_id):add_item(entity)
  radiant.events.trigger(stonehearth.ai, 'stonehearth:pathfinder:reconsider_entity', entity)
  radiant.events.trigger_async(self._entity, "stonehearth:stockpile:item_added", {
      stockpile = self._entity,
      item = entity,
    }
)
end

function StockpileComponent:_remove_item(id)
  local location = self._sv.item_locations[id]

  if location then
    self._sv.item_locations[id] = nil
    self:_remove_from_region(location)
  end

  if self._sv.stocked_items[id] then
    self:_remove_item_from_stock(id)
  end
end

function StockpileComponent:_remove_item_from_stock(id)
  assert(self._sv.stocked_items[id])
  local entity = self._sv.stocked_items[id]
  self._sv.stocked_items[id] = nil
  self.__saved_variables:mark_changed()
  stonehearth.inventory:get_inventory(self._sv.player_id):remove_item(id)
  radiant.events.trigger_async(self._entity, "stonehearth:stockpile:item_removed", {
      stockpile = self._entity,
      item = entity,
    }
)
  if entity and entity:is_valid() then
    radiant.events.trigger(stonehearth.ai, 'stonehearth:pathfinder:reconsider_entity', entity)
  end
end

function StockpileComponent:_rebuild_item_sv()
  assert(self._entity:get_component 'mob':get_parent() ~= nil)
  self._destination:get_region():modify(function(cursor)
      cursor:clear()
      cursor:add_cube(self:_get_bounds())
    end)
  self._destination:get_reserved():modify(function(cursor)
      cursor:clear()
    end)
  self._sv.stocked_items = {}

  self._sv.item_locations = {}

  self.__saved_variables:mark_changed()
  local ec = radiant.entities.get_root_entity():get_component 'entity_container'

  for id, child in ec:each_child() do
    if child and child:is_valid() then
      self:_add_item(child)
    end
  end
end

function StockpileComponent:_assign_to_player()
  local player_id = self._entity:add_component 'unit_info':get_player_id()
  local old_player_id = self._sv.player_id or ""

  if player_id ~= old_player_id then
    self._sv.player_id = player_id
    self.__saved_variables:mark_changed()
    if #old_player_id > 0 then
      local inventory = stonehearth.inventory:get_inventory(old_player_id)
      inventory:remove_storage(self._entity)
    end

    if player_id then
      stonehearth.inventory:get_inventory(player_id):add_stockpile(self._entity)
    end

    self:_create_worker_tasks()
  end
end

function StockpileComponent:_on_item_destroyed(e)
  self:_remove_item(e.entity_id)
end

function StockpileComponent:can_stock_entity(entity)
  return _can_stock_entity(entity, self._sv.filter)
end

function StockpileComponent:_destroy_tasks()
  if self._restock_task then
    log:debug 'destroying restock task'
    self._restock_task:destroy()
    self._restock_task = nil
  end
end

function StockpileComponent:_create_worker_tasks()
  self:_destroy_tasks()
  -- Don't create tasks from now
--   if self._sv.size.x > 0 and self._sv.size.y > 0 then
--     local town = stonehearth.town:get_town(self._entity)

--     if town then
--       log:debug 'creating restock task'
--       self._restock_task = town:create_task_for_group('stonehearth:task_group:restock', 'stonehearth:restock_stockpile', {
--           stockpile = self._entity,
--         }
-- ):set_source(self._entity):set_name 'restock task':set_priority(stonehearth.constants.priorities.simple_labor.RESTOCK_STOCKPILE)

--       if self._sv.active then
--         self._restock_task:start()
--       end
--     end
--   end
end

function StockpileComponent:set_active(active)
  if active ~= self._sv.active then
    self.__saved_variables:modify(function(o)
        o.active = active
      end)
    if self._restock_task then
      if active then
        self._restock_task:start()
      else
        self._restock_task:pause()
      end
    end
  end
end

function StockpileComponent:set_active_command(session, response, active)
  self:set_active(active)
  return true
end

return StockpileComponent