local lfs = require("lfs")
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local interpreter = os.getenv("LUAJIT_BIN") or os.getenv("LUAJIT")
    or (arg and type(arg[-1]) == "string" and not arg[-1]:match("^%-") and arg[-1]) or "luajit"
describe("source finalizer ownership", function()
    it("releases unfinished operations exactly once during GC and VM shutdown", function()
        local directory = os.tmpname()
        os.remove(directory)
        assert(lfs.mkdir(directory))
        local ok, err = pcall(function()
            for _, mode in ipairs({ "unfinished", "collect", "closed" }) do
                local status = os.execute(quote(interpreter) .. " tests/lua/fixtures/source_shutdown.lua " .. mode .. " "
                    .. quote(directory))
                assert.is_true(status == 0 or status == true, "LuaJIT shutdown failed in " .. mode)
                local remaining = 0
                for name in lfs.dir(directory) do
                    if name ~= "." and name ~= ".." then remaining = remaining + 1 end
                end
                assert.are.equal(0, remaining, "source spill/spool leaked in " .. mode)
            end
        end)
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then os.remove(directory .. "/" .. name) end
        end
        lfs.rmdir(directory)
        assert.is_true(ok, err)
    end)
    it("normalizes nested wide objects under a 64-descriptor process limit", function()
        local status = os.execute(quote(interpreter) .. " tests/lua/fixtures/source_deep_spill.lua")
        assert.is_true(status == 0 or status == true, "deep normalization exceeded its file-descriptor workspace")
    end)

end)
