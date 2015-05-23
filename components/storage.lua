local StorageComponent = class()

local function get_binding(entity, data)
   local component = entity:get_component(data.component)
   if not component then
      error('cannot find "' .. tostring(data.component) .. '"" on ' .. tostring(entity))
   end
   return function(...) return component[data.method](component, ...) end
end

-- Constructor
function StorageComponent:initialize(entity, json)
   self._entity = entity

   self._sv = self.__saved_variables:get_data()

   if not self._sv.version then
      self._sv.version = 1
   end

   radiant.events.listen_once(radiant, 'stonehearth:gameloop', function()
      self._can_accept_bind = get_binding(entity, json.can_accept)
      self._is_full_bind = get_binding(entity, json.is_full)
      self._create_restock_task = get_binding(entity, json.create_restock_task)
      
      stonehearth.inventory:add_storage(self._entity)
   end)
end

-- Destructor
function StorageComponent:destroy()
   stonehearth.inventory:remove_storage(self._entity)
end

-- Returns true if this storage does not contain any items
function StorageComponent:is_empty()
   error('NYI')
end

-- Returns true if this storage cannot take any more items; false otherwise
function StorageComponent:is_full()
   return self._is_full_bind()
end

-- Returns true if this entity can be accepted, false otherwise
function StorageComponent:can_accept(item_entity)
   return self._can_accept_bind(item_entity)
end

-- Sub-components have to call this function to trigger an update in the storage service
-- `added_items` are items that were previously not part of the storage, but are now
-- `removed_items` are items that were part of the storage, but are no longer
function StorageComponent:trigger_update(added_items, removed_items)
   stonehearth.inventory:update_storage(self._entity, added_items, removed_items)
end

-- Tells the entity to create a new restock task
-- `entity`: Entity that is to be restocked
function StorageComponent:create_restock_task(entity)
   return self._create_restock_task(entity)
end

return StorageComponent