local StorageComponent = class()

-- Constructor
function StorageComponent:initialize(entity, json)
   self._entity = entity

   self._sv = self.__saved_variables:get_data()

   if not self._sv.version then
      self._sv.version = 1
   end
end

-- Destructor
function StorageComponent:destroy()
end

-- Returns true if this storage does not contain any items
function StorageComponent:is_empty()
   error('NYI')
end

-- Returns true if this storage cannot take any more items; false otherwise
function StorageComponent:is_full()
   error('NYI')
end

-- Returns true if this entity can be accepted, false otherwise
function StorageComponent:can_accept(item_entity)
   if self:is_full() then
      return false
   end

   error('NYI')
end

return StorageComponent