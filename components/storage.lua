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
   if self:is_full() then
      return false
   end

   return self._can_accept_bind(item_entity)
end

return StorageComponent