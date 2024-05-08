--[[
This provides a deadline queue, where the item is retured at the appropriate
tick or soon after if it has already expired.
Keys must be unique for the item. (entity.unit_number)
Values must be a table. The field "_deadline" is added to the table.

Conceptually, this is an infinite series of buckets with each spanning SLICE_TICKS tick.
The buckets are processed until empty and expired. Then we advance to the
next bucket. The prior buckets are always empty, so they are discarded.

Because "infinite" isn't possible, we use a circular queue of size SLICE_COUNT.
If the deadline for an entry is beyond the last bucket, it is placed in the
last bucket.
The next() function will check the deadline and re-add the entry if its
deadline is beyond the bucket's deadline.
In this way, a tick deadline that is beyond (SLICE_TICKS*SLICE_COUNT) is possible.

There are two modes: Exact and Coarse
Exact mode does what you'd expect. An entry is returned by next() only if it
has expired.

Coarse mode will return any entry from the current slice, even if it has not yet
expired. This is specifically for multi-layer queues.
]]
local DeadlineQueue = {}

--[[
Add an item to the queue.

@key (string or number) is the unique key for the item
@val (table) is the value. val._deadline is added
@deadline (number) is the absolute deadline for the entity
@wrap_index (boolean) if true, will place an out-of-bounds deadline in the last slot.
    If false, an out-of-bounds deadline will not be added.
@return whether the item was added to the queue
]]
function DeadlineQueue._queue(self, key, val, deadline, wrap_index)
	-- calculate the relative slice number
	local rel_slice = math.max(0, math.floor(deadline / self.SLICE_TICKS) - self.cur_slice)

	-- limit the relative slice to the size of the circular queue
	if rel_slice >= self.SLICE_COUNT then
    if wrap_index then
		  rel_slice = self.SLICE_COUNT - 1
    else
      return false
    end
	end

	-- calculate the absolute queue index
	local abs_index = 1 + (self.cur_index + rel_slice - 1) % self.SLICE_COUNT

	-- set the deadline field and add it to the queue
	val._deadline = deadline
  self[abs_index][key] = val
  return true
end

--[[
Add an item to the queue.

NOTE: Don't add an item that is already in the queue.
If unsure, call DeadlineQueue.purge() first.
]]
function DeadlineQueue.queue(self, key, val, deadline)
  DeadlineQueue._queue(self, key, val, deadline, true)
end

--[[
Add an item to the queue if the deadline isn't out of range.
This allows using a more coarse DeadlineQueue if the deadline exceeds this one.
Might be more efficient than re-queueing items with distant deadlines.
]]
function DeadlineQueue.queue_maybe(self, key, val, deadline)
  if DeadlineQueue._queue(self, key, val, deadline, false) then
    return true
  end
  return false
end

--[[
Remove a key from the queue.
This is relatively expensive, as it has to access all SLICE_COUNT queues.
]]
function DeadlineQueue.purge(self, key)
	for qq in ipairs(self) do
		qq[key] = nil
	end
end

local function advance_index(self)
		-- advance to the next queue
		-- NOTE: cur_index is base 1, '%' is base 0, so there is an implicit +1
		self.cur_index = 1 + (self.cur_index % self.SLICE_COUNT)
		self.cur_slice = self.cur_slice + 1
		self.deadline = self.deadline + self.SLICE_TICKS
end

--[[
Process the entries in the current queue.
This uses 'exact' mode, meaning that the returned entry will
have an expired deadline.

returns key, value
]]
function DeadlineQueue.next(self)
	local now = game.tick

	while true do
		local deadline = self.deadline
		local qq = self[self.cur_index]
		for key, val in pairs(qq) do
			if now >= val._deadline then
				-- this entry has expired
				qq[key] = nil
				return key, val

			elseif val._deadline > deadline then
				-- this item should not be in this slice. re-add it.
				qq[key] = nil
				DeadlineQueue._queue(self, key, val, val._deadline, true)
			end
		end

		-- bail if there is something in the queue or it hasn't expired
		if next(qq) or now < deadline then
			return -- nil, nil
		end
    advance_index(self)
	end
  -- not reachable
end

--[[
Grab any entries from the current slice.
Specifically for supporting the Dual queue mode.
The returned value may not have expired, but would expire in the current slice.
]]
function DeadlineQueue.next_coarse(self)
	local now = game.tick

	while true do
		local deadline = self.deadline
		local qq = self[self.cur_index]
		for key, val in pairs(qq) do
			if val._deadline > deadline then
				-- this item should not be in this slice. re-add it.
				qq[key] = nil
				DeadlineQueue.queue(self, key, val, val._deadline)

			else
				-- this entry should be returned
				qq[key] = nil
				return key, val
			end
		end

		-- The queue should be empty at this point. Bail if the queue or it hasn't expired.
		if now < deadline then
			return -- nil, nil
		end
    advance_index(self)
	end
  -- not reachable
end

function DeadlineQueue.get_current_count(self)
  return table_size(self[self.cur_index])
end

--[[
Create a new DeadlineQueue instance.
]]
function DeadlineQueue.new(slice_count, slice_ticks)
	local inst = {
		SLICE_TICKS = slice_ticks,
		SLICE_COUNT = slice_count,
		cur_slice = math.floor(game.tick / slice_ticks),
	}
	inst.cur_index = 1 + (inst.cur_slice % slice_count)
	inst.deadline = (1 + inst.cur_slice) * slice_ticks
	-- create the queues
	for idx = 1, slice_count do
		inst[idx] = { }
	end
	return inst
end

return DeadlineQueue
