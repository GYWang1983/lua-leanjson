-- Codec configuration validation. Unlike request loading options, cjson
-- settings accept numeric strings and truncate fractional integer settings.
local M = {}
local function invalid(index, reason)
    -- Native cjson's protected configuration calls report an anonymous callee.
    error("bad argument #" .. index .. " to '?' (" .. reason .. ")", 0)
end

function M.arity(count, maximum)
    if count > maximum then invalid(maximum + 1, "found too many arguments") end
end

function M.integer(value, current, minimum, maximum, index)
    if value == nil then return current end
    local number = (type(value) == "number" or type(value) == "string") and tonumber(value)
    if not number then invalid(index, "number expected, got " .. type(value)) end
    if number ~= number or number == math.huge or number == -math.huge then
        invalid(index, "expected integer between " .. minimum .. " and " .. maximum)
    end
    local integer = number < 0 and math.ceil(number) or math.floor(number)
    if integer < minimum or integer > maximum then
        invalid(index, "expected integer between " .. minimum .. " and " .. maximum)
    end
    return integer
end

function M.boolean(value, current, index)
    if value == nil then return current end
    if value == true or value == "on" then return true end
    if value == false or value == "off" then return false end
    if type(value) ~= "string" and type(value) ~= "number" then
        invalid(index, "string expected, got " .. type(value))
    end
    invalid(index, "invalid option '" .. tostring(value) .. "'")
end

return M
