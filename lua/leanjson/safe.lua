-- cjson-shaped protected conversions with independent codec configuration.
-- Arity/options/configuration errors stay outside the protected operation.
local json = require("leanjson")
local normalize = require("leanjson.options").normalize

local function arity(name, count, minimum, maximum)
    if count < minimum or count > maximum then
        local expected = (name == "decode" or minimum == maximum) and ("expected " .. minimum .. " argument")
            or ("expected " .. minimum .. " to " .. maximum .. " arguments")
        error("bad argument #1 to '?' (" .. expected .. ")", 0)
    end
end

local function protect(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then return nil, value end
    -- Every protected operation here has exactly one success return value.
    -- Testing truthiness would turn a successfully decoded false into failure.
    return value
end

local function new()
    local codec = json.new()
    local safe = {}
    for key, value in pairs(codec) do safe[key] = value end
    safe.new = new
    safe.encode = function(...)
        arity("encode", select("#", ...), 1, 1)
        return protect(codec.encode, ...)
    end
    safe.decode = function(...)
        arity("decode", select("#", ...), 1, 2)
        local raw, opts = ...
        opts = normalize(opts)
        -- luaL_checklstring in native cjson also accepts numeric input.
        if type(raw) == "number" then raw = tostring(raw) end
        return protect(codec.decode, raw, opts)
    end
    safe.decode_file = function(...)
        arity("decode_file", select("#", ...), 1, 2)
        local filename, opts = ...
        opts = normalize(opts)
        return protect(codec.decode_file, filename, opts)
    end
    safe.new_decoder = function(...)
        arity("new_decoder", select("#", ...), 0, 1)
        local opts = normalize(...)
        return protect(codec.new_decoder, opts)
    end
    return safe
end

return new()
