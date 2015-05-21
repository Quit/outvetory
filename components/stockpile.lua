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

-- Table that contains all stockpiles.
-- [stockpile entity id] => [stockpile component]
local all_stockpiles = {}

-- Table that contains all filter functions.
-- [filter string] => [filter function]
local ALL_FILTER_FNS = {}

-- bool _can_stock_entity(Entity entity, table filter)
-- Returns true if `entity` is a valid entity that confirms `filter`
-- If `filter` evaluates to false, this will return false.
--
-- To return true, an entity's iconic form or, if not existent, the entity itself needs to:
-- - have an item component
-- - have a material component
-- - `filter` is either nil, false or a table that contains a material that matches `entity`'s material
local function _can_stock_entity (entity, filter)
  -- Make sure the entity is valid
  if not entity or not entity:is_valid() then
    log:spam('%s is not a valid entity.  cannot be stocked.', tostring(entity))
    return false
  end

  -- If the entity isn't an iconic entity, but has one, check the iconic version.
  -- (because iconic entities, by kinda definition, are the stuff we stock.)
  local efc = entity:get_component 'stonehearth:entity_forms'

  if efc and efc:get_should_restock() then
    local iconic = efc:get_iconic_entity()

    return _can_stock_entity(iconic, filter)
  end

  -- You need to be at least [this] item to be satisfiable.
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

  -- For each entry in the filter table...
  for i, mat in ipairs(filter) do
    if material:is(mat) then
      log:spam('%s matches filter "%s" and can be stocked!', entity, mat)
      return true
    end
  end

  log:spam('%s failed filter.  cannot be stocked.', entity)
  return false
end

-- GLOBAL!
-- Returns the stockpile whose space `entity` technically occupies.
-- So, in other words, this returns the stockpile that `entity` is a part of,
-- although it's not a requirement that `entity` is stocked in that stockpile.
-- It could just lie around and not be stocked (because of unmatching filters or similar).
-- This function basically iterates through all stockpiles, checks all boundaries,
-- and then decides where `entity` would lie.
-- That's kinda unpleasant.
function get_stockpile_containing_entity(entity)
  -- Get the location of the entity
  local location = radiant.entities.get_world_grid_location(entity)

  -- If `entity` has no location, it can't be part of a stockpile.
  if not location then
    return nil
  end

  -- Look for a valid stockpile...
  for id, stockpile in pairs(all_stockpiles) do
    if stockpile then
      local name = tostring(stockpile:get_entity())
      local bounds = stockpile:get_bounds()

      -- That contains `location`
      log:spam('checking to see if %s (pos:%s) is inside a %s', entity, location, name)
      if not bounds:contains(location) then
        log:spam('  %s -> nope! wrong bounds, %s', name, bounds)          
      -- That can take `entity` (i.e. filters allow it)
      elseif not stockpile:can_stock_entity(entity) then
        log:spam('  %s -> nope! cannot stock', name)
      else
        log:spam('  %s -> yup!', name)
        return stockpile
      end
    end
  end
end

-- Initializes the stockpile component. Basic stuff.
function StockpileComponent:initialize(entity, json)
  self._entity = entity
  self._sv = self.__saved_variables:get_data()

  -- 
  if not self._sv.stocked_items then
    self._sv.active = true -- Is this stockpile active? (OBSOLETE?)
    self._sv.size = Point2(0, 0) -- Size of this stockpile in 2D (width, height)

    -- I suppose that stocked_items is a subset of or equal to item_locations.
    self._sv.stocked_items = {} -- Items that are contained in this stockpile (in a properly sorted kind of way): [entity id] => [entity]
    self._sv.item_locations = {} -- Locations of items that are confined within the space of this stockpile... kind of?; [entity id] => [3D world location]

    self._sv.player_id = nil -- Owner of this stockpile.

    -- Assign this stockpile component to our current player (i.e. our entity's player).
    -- Because the stockpile component is added after the entity has been created, and not as part of the entity's definition,
    -- we are somewhat safe to say that we belong to a player at this point.
    self:_assign_to_player()

    -- Set the filter to "allow everything from {{self._sv.player_id}}". The call to _assign_to_player has set the player before.
    self._sv._filter_key = 'stockpile nofilter+' .. self._sv.player_id

    -- Add our destination, and keep track of it.
    self._destination = entity:add_component 'destination'
    -- Create its region already, although it's probably a bit empty. In all regards.
    self._destination:set_region(_radiant.sim.alloc_region3()):set_reserved(_radiant.sim.alloc_region3()):set_auto_update_adjacent(true)
    -- Install the required tracers.
    self:_install_traces()
  -- Otherwise, we're being loaded.
  else
    -- Cache our destination component
    self._destination = entity:get_component 'destination'
    -- Set our reserved region to empty. At this point, we don't have anything planned.
    self._destination:set_reserved(_radiant.sim.alloc_region3())
    -- (Re-?)create the worker tasks.
    self:_create_worker_tasks()
    -- And once the game has finished loading, install the traces.
    radiant.events.listen_once(radiant, 'radiant:game_loaded', function(e)
        self:_install_traces()
      end)
  end

  -- Update our reference in `all_stockpiles`
  all_stockpiles[self._entity:get_id()] = self
end

-- Returns the stockpile's entity.
function StockpileComponent:get_entity()
  return self._entity
end

-- Destructor.
function StockpileComponent:destroy()
  log:info('%s destroying stockpile component', self._entity)

  -- Remove us from the global registry.
  all_stockpiles[self._entity:get_id()] = nil

  -- Remove every item from our stock. Sale! SALE! ( https://www.youtube.com/watch?v=tRxcSNaVCPA )
  for id, item in pairs(self._sv.stocked_items) do
    self:_remove_item_from_stock(id)
  end

  -- Remove this stockpile from our current owner's inventory.
  -- TODO: This means that stockpiles always require an owner. That seems a bit... hm. dunno.
  local player_id = self._entity:add_component 'unit_info':get_player_id()
  stonehearth.inventory:get_inventory(player_id):remove_stockpile(self._entity)

  -- Remove our traces, if they're still left.
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

  -- Kill our AI tasks.
  self:_destroy_tasks()
end

-- Returns the proper filter function for a certain filter key or,
-- if it isn't cached yet, creates it.
-- A filter function's behaviour:
--
-- - If `filter` evaluates to true, it ought to be a table that contains materials that a possible entity needs to fulfill
-- - 
local function get_restock_filter_fn (filter_key, filter, player_id)
  -- Try to look it up first.
  local filter_fn = ALL_FILTER_FNS[filter_key]

  if filter_fn then
      return filter_fn
  end

  -- The table that we pass to `_can_stock_entity` as filter.
  local captured_filter

  -- If a filter table was defined, copy it into `captured_filter`.
  -- Probably to avoid a reference nightmare.
  if filter then
    captured_filter = {}

    for _, material in ipairs(filter) do
      table.insert(captured_filter, material)
    end
  end

  -- The filter function itself.
  function filter_fn(item)
    log:detail('calling filter function on %s', item)

    -- Get the owner of the entity and check if it's the same as the passed player
    local item_player_id = radiant.entities.get_player_id(item)
    if item_player_id ~= player_id then
      log:detail('item player id "%s" ~= stockpile id "%s".  returning from filter function', item_player_id, player_id)
      return false
    end

    -- Get the current stockpile of the item and its entity
    local containing_component = get_stockpile_containing_entity(item)
    local containing_entity = containing_component and containing_component:get_entity()

    -- If there is an entity (which is kinda implied if the component exists)...
    if containing_entity then
      -- In this case, the entity is already part of a stockpile. So, we're talking about... uh...
      -- peaceful relocation of well deserved items?

      -- The game master (by default enabled) spoils this fun, however.
      if stonehearth.game_master:is_enabled() then
        log:detail 'already stocked!  returning false from filter function'
        return false
      end

      -- Otherwise, get the owner of the *current* stockpile.
      local containing_stockpile_owner_id = radiant.entities.get_player_id(containing_entity)
      log:detail('item:      %s', radiant.entities.get_player_id(item))
      log:detail('stockpile: %s', containing_stockpile_owner_id)

      -- If the current owner is neutral, or friendly, towards us...
      local already_stocked = not radiant.entities.are_players_hostile(player_id, containing_stockpile_owner_id)

      -- ... we're not looting him. Yet. But he better watch out.
      if already_stocked then
        log:detail 'already stocked!  returning false from filter function'
        return false
      else
        log:detail 'item in stockpile, but not one of ours.'
      end
    end

    -- Congratulations! If `entity` made it this far...
    -- Run the normal check for the filter table to see if this item is available.
    return _can_stock_entity(item, captured_filter)
  end

  -- Cache the function and return it.
  ALL_FILTER_FNS[filter_key] = filter_fn

  return filter_fn
end

-- Returns the current filter function.
function StockpileComponent:get_filter()
  return get_restock_filter_fn(self._sv._filter_key, self._sv.filter, self._sv.player_id)
end

-- Sets the current filter.
-- `filter` is either nil (not prefered but also possible I guess `false`) OR
-- a table that contains materials that are allowed in.
function StockpileComponent:set_filter(filter)
  -- Set the filter already. Welcome to the family!
  self._sv.filter = filter

  -- The following code sets the filter key and the filter function.
  -- Filter keys are unique identifiers that specify a filter function.
  -- They're defining a function by using (player, filters) as a key.
  -- Therefore, every stockpile of the same player with the same filter
  -- has the same key and therefore the same filter function.
  -- Hooray caching. 

  -- If the filter is set (i.e. we do have restrictions)...
  if self._sv.filter then
    
    self._sv._filter_key = 'stockpile filter:'
    table.sort(self._sv.filter)
    for _, material in ipairs(self._sv.filter) do
      self._sv._filter_key = self._sv._filter_key .. '+' .. material
    end
  -- Otherwise, no filter applies.
  else
    self._sv._filter_key = 'stockpile nofilter'
  end

  -- Append as last part of our filter the player id.
  self._sv._filter_key = self._sv._filter_key .. '+' .. self._sv.player_id
  -- Save the changed variables.
  self.__saved_variables:mark_changed()

  -- Now, for each item...
  for id, location in pairs(self._sv.item_locations) do
    -- Get the entity
    local item = radiant.entities.get_entity(id)
    local can_stock = self:can_stock_entity(item)
    local is_stocked = self._sv.stocked_items[id] ~= nil

    -- If the entity can be stocked, but currently isn't, our filter was expanded (i.e. less restrictive).
    -- This entity is now mine.
    if can_stock and not is_stocked then
      self:_add_item_to_stock(item)
    end

    -- If the entity cannot be stocked, but is, our filter was reduced (i.e. more restrictive).
    -- This entity is no longer mine. :(
    if not can_stock and is_stocked then
      self:_remove_item_from_stock(item:get_id())
    end
  end

  -- Kill current worker tasks, and create new ones.
  self:_create_worker_tasks()

  -- Fire an event. This event is currently not used anywhere... I think?
  radiant.events.trigger_async(self._entity, 'stonehearth:stockpile:filter_changed')
  return self
end

-- Installs various traces that keep track of stuff.
function StockpileComponent:_install_traces()
  -- Install traces that tell us when items are added and removed from the root entity
  -- This means, more or less, "inform us whenever an entity is dropped or picked up from the ground"
  -- Basically, stockpiles are greedy. Really greedy. They'll consider every entity they see as "theirs".
  local ec = radiant.entities.get_root_entity():get_component 'entity_container'
  self._ec_trace = ec:trace_children 'tracking stockpile':on_added(function(id, entity)
      self:_add_item(entity)
    end):on_removed(function(id, entity)
      self:_remove_item(id)
    end)

  -- Track changes. I... don't think that happens. Ever.
  local mob = self._entity:add_component 'mob'
  self._mob_trace = mob:trace_transform 'stockpile tracking self position':on_changed(function()
      error('stockpile mob trace trap')
      self:_rebuild_item_sv()
    end)

  -- Track player changes. This... maybe happens? Hostile takeovers of stockpiles?
  local unit_info = self._entity:add_component 'unit_info'
  self._unit_info_trace = unit_info:trace_player_id 'stockpile tracking player_id':on_changed(function()
      self:_assign_to_player()
    end)

  -- Listen to destroyed entities. This basically considers them removed.
  self._destroy_listener = radiant.events.listen(radiant, 'radiant:entity:post_destroy', self, self._on_item_destroyed)
end

-- Returns all items that we have stocked.
function StockpileComponent:get_items()
  return self._sv.stocked_items
end

-- Returns the bounding box in local space.
function StockpileComponent:_get_bounds()
  local size = self:get_size()
  local bounds = Cube3(Point3(0, 0, 0), Point3(size.x, 1, size.y))

  return bounds
end

-- Returns the bounding box in world space.
function StockpileComponent:get_bounds()
  local origin = radiant.entities.get_world_grid_location(self._entity)

  if not origin then
    return nil
  end

  local size = self:get_size()
  return Cube3(origin, Point3(origin.x + size.x, origin.y + 1, origin.z + size.y))
end

-- Returns if this stockpile is full.
function StockpileComponent:is_full()
  if self._destination and self._destination:is_valid() then
    return self._destination:get_region():get():empty()
  end

  return true
end

-- Returns if `item_entity` is, technically, occupying space in this stockpile.
function StockpileComponent:bounds_contain(item_entity)
  local world_bounds = self:get_bounds()

  -- Should we, for whatever reason, currently not occupy normal dimensions...
  -- well, we couldn't take care of an item then, at least not responsibly.
  if not world_bounds then
    return false
  end

  local location = radiant.entities.get_world_grid_location(item_entity)
  return world_bounds:contains(location)
end

-- Returns the size of the stockpile as Point2
function StockpileComponent:get_size()
  return self._sv.size
end

-- Sets the size of the stockpile.
function StockpileComponent:set_size(x, y)
  self._sv.size = Point2(x, y)
  self:_rebuild_item_sv()
  self:_create_worker_tasks()
end

-- AI callback whenever something is dropped into a stockpile.
-- This will remove `location` from the list of possible spots for
-- something to be put into.
function StockpileComponent:notify_restock_finished(location)
  if self._entity:is_valid() then
    self:_add_to_region(location)
  end
end

-- Marks `location` as occupied by an item. Updates the destination region.
function StockpileComponent:_add_to_region(location)
  log:debug('adding point %s to region', tostring(location))
  local offset = location - radiant.entities.get_world_grid_location(self._entity)
  local was_full = self:is_full()

  -- Remove the point from the area of possible spaces.
  self._destination:get_region():modify(function(cursor)
      cursor:subtract_point(offset)
    end)

  -- If we weren't full, but are now, fire an event that tells the AI actions to stop the action.
  -- (reserving the stockpile space isn't working)
  if not was_full and self:is_full() then
    radiant.events.trigger(self._entity, 'stonehearth:stockpile:space_available', self, false)
  end
end

-- Marks `location` as unused by an item. Updates the destination region.
function StockpileComponent:_remove_from_region(location)
  log:debug('removing point %s from region', tostring(location))
  local offset = location - radiant.entities.get_world_grid_location(self._entity)
  local was_full = self:is_full()

  -- Remove the point from the area of possible spaces. Back in the game!
  self._destination:get_region():modify(function(cursor)
      cursor:add_point(offset)
    end)

  -- If we've got space again, fire an event, tell the AI that they can start looking again.
  if was_full and not self:is_full() then
    radiant.events.trigger(self._entity, 'stonehearth:stockpile:space_available', self, true)
  end
end

-- Attempts to add `entity` to this stockpile.
-- If it's within the bounds (and has an item component), it will occupy a space.
function StockpileComponent:_add_item(entity)
  if self:bounds_contain(entity) and entity:get_component 'item' then
    local location = radiant.entities.get_world_grid_location(entity)
    log:debug('adding %s to occupied items', entity)
    self:_add_to_region(location)

    -- BUG! ... I believe? We added this entity to our space, but haven't stored it anywhere. 
    -- That means that our grid is kind of invalidated, i.e. we have a space leak.
    -- So, fix it.
    self._sv.item_locations[entity:get_id()] = location

    -- If this item cna *also* be stocked in this stockpile, great!
    if self:can_stock_entity(entity) then
      log:debug('adding %s to stock', entity)
      self:_add_item_to_stock(entity)
    end

    -- Better save than sorry. Haha.
    self.__saved_variables:mark_changed()
  end
end

-- Stocks an item in this stockpile. Requirement is that the entity can be stocked and is within the bounds.
function StockpileComponent:_add_item_to_stock(entity)
  assert(self:can_stock_entity(entity) and self:bounds_contain(entity), 'entity cannot be stocked or out of bounds')

  -- Get the location of said entity
  local location = radiant.entities.get_world_grid_location(entity)

  -- For debugging purposes only, it seems, check if we're going to stack something.
  for id, existing in pairs(self._sv.stocked_items) do
    if radiant.entities.get_world_grid_location(existing) == location then
      log:error('putting %s on top of existing item %s in stockpile (location:%s)', entity, existing, location)
    end
  end

  -- Wire everything up:
  local id = entity:get_id()
  -- Mark this location as occupied
  self._sv.item_locations[id] = location
  -- Mark this entity as stocked
  self._sv.stocked_items[id] = entity
  -- Save.
  self.__saved_variables:mark_changed()

  -- Inform our inventory that one item was added
  stonehearth.inventory:get_inventory(self._sv.player_id):add_item(entity)

  -- Tell our PF to reconsider the entity. This will just kick the BFS to check that entity again, or something.
  radiant.events.trigger(stonehearth.ai, 'stonehearth:pathfinder:reconsider_entity', entity)
  -- Trigger an event on the stockpile.
  radiant.events.trigger_async(self._entity, "stonehearth:stockpile:item_added", 
  {
    stockpile = self._entity,
    item = entity,
  })
end

-- Removes this entity completely from this stockpile.
-- Un-locates and un-stocks.
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

-- Removes an entity from stock only.
function StockpileComponent:_remove_item_from_stock(id)
  assert(self._sv.stocked_items[id], 'attempt to remove an unstocked entity')

  -- Get the entity. This is ~similar to just radiant.entities.get_entity() I guess.
  local entity = self._sv.stocked_items[id]

  -- Unstock; save
  self._sv.stocked_items[id] = nil
  self.__saved_variables:mark_changed()

  -- Remove from inventory
  stonehearth.inventory:get_inventory(self._sv.player_id):remove_item(id)

  -- Trigger event.
  radiant.events.trigger_async(self._entity, "stonehearth:stockpile:item_removed", 
  {
    stockpile = self._entity,
    item = entity,
  })

  -- If the entity is still valid, force PFs to reconsider it.
  if entity and entity:is_valid() then
    radiant.events.trigger(stonehearth.ai, 'stonehearth:pathfinder:reconsider_entity', entity)
  end
end

-- In case major changes happened, e.g. the stockpile has moved (however *that* is possible),
-- or the filter has changed, or the size has changed, or for any reason we need to
-- re-evaluate all items in our area whether they're in our out...
-- This function does it.
function StockpileComponent:_rebuild_item_sv()
  assert(self._entity:get_component 'mob':get_parent() ~= nil, 'detached stockpile cannot rebuild item save')

  -- Clear our destination region; nobody is going to use it.
  self._destination:get_region():modify(function(cursor)
      cursor:clear()
      cursor:add_cube(self:_get_bounds())
    end)

  -- Clear our reserved region; nobody may use it.
  self._destination:get_reserved():modify(function(cursor)
      cursor:clear()
    end)

  -- Reset stocked and available items; save
  self._sv.stocked_items = {}
  self._sv.item_locations = {}
  self.__saved_variables:mark_changed()

  -- Try to optimize a bit by only iterating through items that are *actually in our bounds*
  -- Add those.
  for id, item in pairs(radiant.terrain.get_entities_in_cube(self:get_bounds())) do
    if item and item:is_valid() then
      self:_add_item(item)
    end
  end
end

-- Assigns the stockpile to the stockpile entity's current owner.
-- This will mostly change the inventory component, i.e. what you own.
function StockpileComponent:_assign_to_player()
  -- Get the current owner and the old owner
  local player_id = self._entity:add_component 'unit_info':get_player_id()
  local old_player_id = self._sv.player_id or ""

  -- If there was a change...
  if player_id ~= old_player_id then
    -- We, for one, welcome our new player overlord
    self._sv.player_id = player_id
    self.__saved_variables:mark_changed()

    -- If the old player id was *something* (i.e. the stockpile belonged to somebody)
    if #old_player_id > 0 then
      -- Remove it from the old player's inventory
      local inventory = stonehearth.inventory:get_inventory(old_player_id)
      inventory:remove_storage(self._entity)
    end

    -- If we have a new owner...
    if player_id then
      -- Add us to the new player's inventory
      stonehearth.inventory:get_inventory(player_id):add_stockpile(self._entity)
    end

    -- And because we had some changes, tear down our old tasks and create new ones
    self:_create_worker_tasks()
  end
end

-- Callback from a trace; whenever an item is destroyed, count it as removed.
function StockpileComponent:_on_item_destroyed(e)
  self:_remove_item(e.entity_id)
end

-- Callback for the AI (maybe?) and helper function in general.
-- Tells if `entity` can be stocked, or rather, matches the stockpile's filters.
function StockpileComponent:can_stock_entity(entity)
  return _can_stock_entity(entity, self._sv.filter)
end

-- Kills all dependent restock tasks... Or rather, *the* restock task?
function StockpileComponent:_destroy_tasks()
  if self._restock_task then
    log:debug 'destroying restock task'
    self._restock_task:destroy()
    self._restock_task = nil
  end
end

-- Creates the task to restock this stockpile.
function StockpileComponent:_create_worker_tasks()
  self:_destroy_tasks()

  if self._sv.size.x > 0 and self._sv.size.y > 0 then
    local town = stonehearth.town:get_town(self._entity)

    if town then
      log:debug 'creating restock task'
      self._restock_task = town:create_task_for_group('stonehearth:task_group:restock', 'stonehearth:restock_stockpile', {
          stockpile = self._entity,
        }
):set_source(self._entity):set_name 'restock task':set_priority(stonehearth.constants.priorities.simple_labor.RESTOCK_STOCKPILE)

      if self._sv.active then
        self._restock_task:start()
      end
    end
  end
end

-- OBSOLETE?
function StockpileComponent:set_active(active)
  error('StockpileComponent:set_active trap')
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

-- OBSOLETE?
function StockpileComponent:set_active_command(session, response, active)
  error('StockpileComponent:set_active_command trap')
  self:set_active(active)
  return true
end

return StockpileComponent
