-- Conversion for tokens already validated by the source scanner. The pinned
-- OpenResty cjson uses strtoll for plain decimal integers (with saturation)
-- and strtod for the other numeric spellings. No native cjson dependency.
local M = {}
local ffi = require("ffi")
ffi.cdef[[
void *newlocale(int category_mask, const char *locale, void *base);
double strtod_l(const char *text, char **endptr, void *locale);
]]
ffi.cdef((ffi.os == "OSX" and "int" or "void") .. " freelocale(void *locale);")
local c_locale
local function extended_number(raw)
    -- LuaJIT's exponent scanner has a smaller range than strtod. Use a
    -- private C numeric locale without changing process-wide locale state.
    if not c_locale then
        local locale = ffi.C.newlocale(ffi.os == "OSX" and 16 or 2, "C", nil)
        if locale == nil then error("leanjson: cannot create numeric locale", 0) end
        c_locale = ffi.gc(locale, ffi.C.freelocale)
    end
    local finish = ffi.new("char *[1]")
    local input = ffi.cast("const char *", raw)
    local number = ffi.C.strtod_l(input, finish, c_locale)
    if finish[0] ~= input + #raw then error("leanjson: invalid number format", 0) end
    return number
end
function M.decode(raw)
    local first = 1
    local negative = raw:byte(1) == 45
    if negative or raw:byte(1) == 43 then first = 2 end
    local initial = raw:byte(first)
    if (initial == 110 or initial == 78) and raw:sub(first, first + 2):lower() == "nan" then return 0/0 end
    if raw:match("^[+-]?%d+$") then
        local nonzero = raw:find("[1-9]", first)
        if not nonzero then return 0 end
        local digits = #raw - nonzero + 1
        local limit = negative and "9223372036854775808" or "9223372036854775807"
        if digits > 19 or (digits == 19 and raw:sub(nonzero) > limit) then
            return negative and -9223372036854775808 or 9223372036854775807
        end
    end
    local number = tonumber(raw)
    if number == nil then return extended_number(raw) end
    return number
end
return M
