

# TODO

# Re-queue entities on recipe change

  - check on gui closed
  - check on

# Hidden Sink Check leftovers

sink chest is leaving a arr-hidden-sink-chest on copy/paste.
I probably broke it.

1448.891 Script @__auto-resource-redux__/src/EntityManager.lua:103: Managing 840 (name=entity-ghost, type=entity-ghost, queue=entity-ghost)
1448.891 Script @__auto-resource-redux__/src/EntityManager.lua:103: Managing 851 (name=arr-hidden-sink-chest, type=container, queue=sink-chest)

# handlers

 * assemblers (recipe based)
 * furnace (pseudo-recipe based)
 * fuel
 * ammo
 * ?


# Options

 - Disable the hidden chest for drills, etc. Forces the use of output belts/chests.
 - Disabled adding ingredients to assemblers, forces the use of inserters, belts, etc
 - Disable disposing of fluids OR adding fluids -- only pipes!


# Add a shortages page

Track shortages -- not just '0' items.
Color of the items should be:
  - RED : below
