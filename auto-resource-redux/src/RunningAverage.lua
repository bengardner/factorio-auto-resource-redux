--[[
Tracks a fixed length of samples in a circular queue to compute a sum and average.
]]
local RunningAverage = {}

-- Create a new RunningAverage instance
---@param size number
---@return table # new RunningAverage instance
function RunningAverage.new(size)
  if size < 1 then
    size = 1
  end
  local inst = {
    sum = 0,
    idx = 1
  }
  for i = 1, size do
    inst[i] = 0
  end
  return inst
end

--- Resets the sum and average to 0.
---@param self table # value from RunningAverage.new()
function RunningAverage.reset(self)
  self.sum = 0
end

---Adds a sample to the average.
---@param self table # value from RunningAverage.new()
---@param value number # new sample value
function RunningAverage.add_sample(self, value)
  -- subtract the old sample and add the new sample
  self.sum = self.sum - self[self.idx] + value
  self[self.idx] = value

  -- point to the next sample
  self.idx = 1 + (self.idx % #self)
end

--- Get the sum of all samples.
---@param self table # value from RunningAverage.new()
---@return number # sum of all samples
function RunningAverage.get_sum(self)
  return self.sum
end

--- Get the average of all samples.
---@param self table # value from RunningAverage.new()
---@return number # average of all samples
function RunningAverage.get_average(self)
  return self.sum / #self
end

return RunningAverage
