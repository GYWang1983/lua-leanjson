-- Deliberate invalid access for the verification runner's negative control.
-- Run only under Memcheck; this is not part of the ordinary Busted suite.
local ffi = require("ffi")
ffi.cdef[[void *malloc(size_t size); void free(void *pointer);]]
local allocation = assert(ffi.C.malloc(1))
ffi.cast("volatile uint8_t *", allocation)[1] = 42
ffi.C.free(allocation)
print("invalid-write control reached")
