if mods["nullius"] then

  -- add all recipes and items that should be used with nullius
  local all_items = {
    ["arr-combinator"] = true,
    ["arr-logistic-sink-chest"] = true,
    ["arr-logistic-requester-chest"] = true,
    ["arr-requester-tank"] = true,
    ["arr-sink-tank"] = true,
  }

  for k, _ in pairs(all_items) do
    local item = data.raw.item[k]
    if item ~= nil then
      item.order = "nullius-" .. (item.order or k)
    end
    local recipe = data.raw.recipe[k]
    if recipe ~= nil then
      recipe.order = "nullius-" .. (recipe.order or k)
    end
  end
end
