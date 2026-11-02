std             = "luajit"
max_line_length = false
unused_args     = false
redefined       = false

files["tests/lua/**/*.lua"] = {
    std = "luajit+busted",
}

files["lua/leanjson/openresty.lua"] = { globals = { "ngx" } }
files["examples/openresty/**/*.lua"] = { globals = { "ngx" } }
files["tests/openresty/**/*.lua"] = { globals = { "ngx" } }
