local DomainStore = {}

function DomainStore.get_domain_key(entity)
  if global.combine_surfaces == true then
    return string.format("0-%s", entity.force.name)
  end
  return string.format("%d-%s", entity.surface.index, entity.force.name)
end

function DomainStore.get_domain_key_raw(surface_id, force_name)
  if global.combine_surfaces == true then
    return string.format("0-%s", force_name)
  end
  return string.format("%d-%s", surface_id, force_name)
end

function DomainStore.get_subdomain(domain_key, subdomain_key, default_fn)
  local domain = global.domains[domain_key]
  if domain == nil then
    domain = {}
    global.domains[domain_key] = domain
  end
  local subdomain = domain[subdomain_key]
  if subdomain == nil then
    subdomain = default_fn(domain_key)
    domain[subdomain_key] = subdomain
  end
  return subdomain
end

function DomainStore.initialise()
  if global.domains == nil then
    global.domains = {}
  end
end

local function sort_storage(combined)
  -- TODO: if combined, move everything to the 'surface 0' store
  -- Can't be undone.
end

function DomainStore.on_runtime_mod_setting_changed(event)
  local new_value = settings.global["auto-resource-redux-combine-surfaces"].value
  local old_value = global.combine_surfaces or false
  if old_value ~= new_value then
    global.combine_surfaces = new_value
    sort_storage(new_value)
  end
end

return DomainStore
