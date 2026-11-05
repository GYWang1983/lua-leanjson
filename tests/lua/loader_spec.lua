describe("leanjson native loader", function()
    it("reports attempted libraries and the last loader error", function()
        local old_lib = package.loaded["leanjson.lib"]
        local old_ffi = package.loaded.ffi
        local old_cpath = package.cpath

        package.loaded["leanjson.lib"] = nil
        package.loaded.ffi = {
            cdef = function() end,
            load = function(name)
                error("mock load failure for " .. name)
            end,
        }
        package.cpath = "/tmp/leanjson-test/?.so;/tmp/leanjson-test/loadall.so"

        local ok, err = pcall(require, "leanjson.lib")

        package.loaded["leanjson.lib"] = old_lib
        package.loaded.ffi = old_ffi
        package.cpath = old_cpath

        assert.is_false(ok)
        assert.matches("leanjson: failed to load native library leanjson", err, 1, true)
        assert.matches("leanjson, libleanjson, /tmp/leanjson-test/leanjson.so, /tmp/leanjson-test/libleanjson.so", err, 1, true)
        assert.matches("mock load failure for /tmp/leanjson-test/libleanjson.so", err, 1, true)
        assert.is_nil(string.find(err, "loadall.so", 1, true))
    end)

    it("skips loadable libraries without leanjson symbols", function()
        local old_lib = package.loaded["leanjson.lib"]
        local old_ffi = package.loaded.ffi
        local old_cpath = package.cpath
        local valid_lib = setmetatable({}, {
            __index = function(_, key)
                if string.sub(key, 1, #"leanjson_") == "leanjson_" then
                    return true
                end
            end,
        })

        package.loaded["leanjson.lib"] = nil
        package.loaded.ffi = {
            cdef = function() end,
            load = function(name)
                if name == "leanjson" then
                    return {}
                end
                if name == "libleanjson" then
                    return valid_lib
                end
                error("unexpected load: " .. name)
            end,
        }
        package.cpath = ""

        local ok, lib = pcall(require, "leanjson.lib")

        package.loaded["leanjson.lib"] = old_lib
        package.loaded.ffi = old_ffi
        package.cpath = old_cpath

        assert.is_true(ok)
        assert.are.equal(valid_lib, lib)
    end)
    it("rejects an otherwise complete library missing the additive sparse ABI", function()
        local old_lib, old_ffi, old_cpath = package.loaded["leanjson.lib"], package.loaded.ffi, package.cpath
        package.loaded["leanjson.lib"] = nil
        package.loaded.ffi = {
            cdef = function() end,
            load = function()
                return setmetatable({}, { __index = function(_, symbol)
                    if symbol == "leanjson_source_v2_new" then error("missing sparse ABI") end
                    return true
                end })
            end,
        }
        package.cpath = ""
        local ok, err = pcall(require, "leanjson.lib")
        package.loaded["leanjson.lib"], package.loaded.ffi, package.cpath = old_lib, old_ffi, old_cpath
        assert.is_false(ok)
        assert.matches("missing required symbol leanjson_source_v2_new", err, 1, true)
    end)

    it("rejects a sparse library missing scan-time loading exports", function()
        local old_lib, old_ffi, old_cpath = package.loaded["leanjson.lib"], package.loaded.ffi, package.cpath
        package.loaded["leanjson.lib"] = nil
        package.loaded.ffi = { cdef = function() end, load = function()
            return setmetatable({}, { __index = function(_, symbol)
                if symbol == "leanjson_source_v2_next_loading_event" then error("missing loading ABI") end
                return true
            end })
        end }
        package.cpath = ""
        local ok, err = pcall(require, "leanjson.lib")
        package.loaded["leanjson.lib"], package.loaded.ffi, package.cpath = old_lib, old_ffi, old_cpath
        assert.is_false(ok)
        assert.matches("missing required symbol leanjson_source_v2_next_loading_event", err, 1, true)
    end)

    it("rejects stale libraries missing any scanner entry point", function()
        for _, missing in ipairs({"leanjson_source_v2_set_scanner", "leanjson_source_v2_feed_memory", "leanjson_source_v2_finish_memory"}) do
            local old_lib, old_ffi, old_cpath = package.loaded["leanjson.lib"], package.loaded.ffi, package.cpath
            package.loaded["leanjson.lib"] = nil
            package.loaded.ffi = { cdef = function() end, load = function()
                return setmetatable({}, { __index = function(_, symbol)
                    if symbol == missing then error("missing scanner ABI") end
                    return true
                end })
            end }
            package.cpath = ""
            local ok, err = pcall(require, "leanjson.lib")
            package.loaded["leanjson.lib"], package.loaded.ffi, package.cpath = old_lib, old_ffi, old_cpath
            assert.is_false(ok)
            assert.matches("missing required symbol " .. missing, err, 1, true)
        end
    end)

end)
