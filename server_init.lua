local patch = require('lib.patch')

outvetory = class()

function outvetory:__init()
   radiant.events.listen(radiant, 'radiant:required_loaded', self, self._patch_all)
end

function outvetory:_patch_all()
   jelly.patch.lua('stonehearth.components.stockpile.stockpile_component', 'outvetory.components.stockpile')
end

return outvetory()