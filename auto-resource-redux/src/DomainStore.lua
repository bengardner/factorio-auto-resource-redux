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
    global.combine_surfaces = settings.startup["auto-resource-redux-combine-surfaces"].value
  end
end

return DomainStore
