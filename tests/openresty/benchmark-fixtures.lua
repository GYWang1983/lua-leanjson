-- Construct fixtures outside measured workers. Identical bytes are shared by
-- cjson and LeanJSON; repeated-key fixtures deliberately retain lexical order.
local cjson = require "cjson"
local M = {}

function M.build(scenario, size)
    local count = math.max(1, math.floor(size / 32))
    if scenario == "messages" then
        return '{"model":"original","messages":[{"role":"user","content":' .. cjson.encode(("m"):rep(size)) .. '}]}'
    elseif scenario == "input" then
        return '{"model":"original","input":' .. cjson.encode(("i"):rep(size)) .. '}'
    elseif scenario == "escaped" then
        return '{"model":"original","prompt":' .. cjson.encode(("\n\t\"\\"):rep(math.floor(size / 8))) .. '}'
    elseif scenario == "short-elements" or scenario == "duplicate-tail" or scenario == "deep-objects" then
        local items = {}
        for i = 1, count do
            if scenario == "duplicate-tail" then
                items[i] = '{"id":0,"id":' .. i .. ',"\\u0076alue":"old","value":"small"}'
            elseif scenario == "deep-objects" then
                items[i] = '{"a":{"b":{"c":{"d":{"e":{"id":' .. i .. ',"value":"small"}}}}}}'
            else items[i] = '{"id":' .. i .. ',"value":"small"}' end
        end
        return '{"model":"original","items":[' .. table.concat(items, ",") .. ']}'
    elseif scenario == "wide-objects" or scenario == "wide-scalars" or scenario == "wide-duplicates" then
        local fields = { '"model":"original"' }
        for i = 1, count do
            local value = scenario == "wide-scalars" and tostring(i) or '{"id":' .. i .. ',"value":"small"}'
            fields[#fields + 1] = '"k' .. i .. '":' .. value
        end
        if scenario == "wide-duplicates" then
            for i = 1, count do
                fields[#fields + 1] = '"\\u006b' .. i .. '":{"id":' .. i .. ',"value":"last"}'
            end
        end
        return "{" .. table.concat(fields, ",") .. "}"
    elseif scenario == "prompt" or scenario == "explicit" or scenario == "cold" then
        return '{"model":"original","prompt":' .. cjson.encode(("p"):rep(size)) .. '}'
    end
    error("unknown benchmark scenario: " .. tostring(scenario))
end

return M
