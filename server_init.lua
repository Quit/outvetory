local patch = require('lib.patch')

if not rawget(_G, 'printf') then
   rawset(_G, 'printf', function() end)
end

outvetory = class()

function outvetory:__init()
   -- Patch everything in advance.
   patch.lua('stonehearth.services.server.inventory.inventory_service', 'outvetory.services.server.inventory.inventory_service')
   patch.lua('stonehearth.components.stockpile.stockpile_component', 'outvetory.components.stockpile')
end

return outvetory()