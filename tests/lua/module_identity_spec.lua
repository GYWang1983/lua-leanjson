local json = require("leanjson")
local safe = require("leanjson.safe")

describe("LeanJSON module identity", function()
    local surfaces = {
        { "module", function() return json end },
        { "instance", function() return json.new() end },
        { "nested instance", function() return json.new().new() end },
        { "safe module", function() return safe end },
        { "safe instance", function() return safe.new() end },
        { "nested safe instance", function() return safe.new().new() end },
    }

    for _, surface in ipairs(surfaces) do
        it("identifies the " .. surface[1] .. " without impersonating cjson", function()
            local codec = surface[2]()
            assert.equal("leanjson", codec._NAME)
            assert.equal("0.1.1", codec._VERSION)
            assert.equal("leanjson/0.1.1", ("%s/%s"):format(codec._NAME, codec._VERSION))
        end)
    end

    it("reports the package release version", function()
        local file = assert(io.open("Cargo.toml", "rb"))
        local manifest = file:read("*a")
        file:close()
        local version = assert(manifest:match('^%[package%].-version%s*=%s*"([^"]+)"'))
        assert.equal(version, json._VERSION)
    end)
end)
