-- Immutable input chunks, addressed by absolute byte offset. Keep source bytes
-- without a whole-body concat, a second parse or native allocator ownership.
local M = {}
local Buffer = {}; Buffer.__index = Buffer

function M.new() return setmetatable({ chunks = {}, ends = {}, length = 0 }, Buffer) end

function Buffer:append(value, first, length)
    if length == 0 then return end
    local chunk = first == 0 and length == #value and value or value:sub(first + 1, first + length)
    self.length = self.length + length
    self.chunks[#self.chunks + 1] = chunk
    self.ends[#self.ends + 1] = self.length
end

function Buffer:read(offset, length)
    if offset >= self.length then return "" end
    local low, high = 1, #self.ends
    while low < high do
        local middle = math.floor((low + high) / 2)
        if self.ends[middle] <= offset then low = middle + 1 else high = middle end
    end
    local first = offset - (low == 1 and 0 or self.ends[low - 1]) + 1
    -- Short windows are intentional: the native consumer requests another
    -- window when a token crosses a stored chunk boundary.
    return self.chunks[low]:sub(first, first + length - 1)
end

function Buffer:close() self.chunks, self.ends, self.length = {}, {}, 0 end

return M
