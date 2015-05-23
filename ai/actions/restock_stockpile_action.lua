local Entity = _radiant.om.Entity
local RestockStockpile = class()
RestockStockpile.name = 'restock stockpile'
RestockStockpile.does = 'outvetory:restock_stockpile'
RestockStockpile.args = {
  stockpile = Entity,
  entity = Entity
}

RestockStockpile.version = 2
RestockStockpile.priority = 1

function RestockStockpile:start(ai, entity, args)
  ai:set_status_text('restocking ' .. radiant.entities.get_name(args.stockpile) .. ' with ' .. radiant.entities.get_name(args.entity))
end

local ai = stonehearth.ai

return ai:create_compound_action(RestockStockpile):execute('stonehearth:wait_for_stockpile_space', {
    stockpile = ai.ARGS.stockpile,
  }
):execute('stonehearth:pickup_item', {
    item = ai.ARGS.entity
  }
):execute('stonehearth:drop_carrying_in_stockpile', {
    stockpile = ai.ARGS.stockpile,
  }
)
