ARG RUST_IMAGE=rust:1.90.0-slim-bookworm@sha256:64232e656c058f4468e8d024e990acff04f0fd5a5c0a88a574dc37773d7325c9
ARG OPENRESTY_IMAGE=openresty/openresty:1.29.2.4-0-jammy@sha256:0a887716d1bc7a3d38e6a765e4c9df31a4b4e27473fc30def6601511330c7f2f
FROM ${RUST_IMAGE} AS rust-toolchain
RUN rustup component add clippy

FROM ${OPENRESTY_IMAGE} AS dev
ENV DEBIAN_FRONTEND=noninteractive \
    CARGO_HOME=/usr/local/cargo RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:/usr/local/openresty/bin:/usr/local/openresty/luajit/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LUA_PATH='/workspace/lua/?.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;' \
    LUA_CPATH='/usr/local/openresty/lualib/?.so;/usr/local/lib/lua/5.1/?.so;;' \
    LD_LIBRARY_PATH=/workspace/target/release
RUN apt-get install -y --no-install-recommends --no-upgrade \
    lua5.1=5.1.5-8.1build4 liblua5.1-0-dev=5.1.5-8.1build4 luarocks=3.8.0+dfsg1-1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=rust-toolchain /usr/local/cargo /usr/local/cargo
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup
# Pin the complete Lua test dependency set, including transitive rocks. Native
# OpenResty's bundled cjson stays first on the runtime module path.
RUN for rock in 'argparse 0.7.2-1' 'dkjson 2.11-1' 'luafilesystem 1.9.0-1' \
    'luasystem 0.7.1-1' 'lua-term 0.8-1' 'lua_cliargs 3.0-2' 'say 1.4.1-3' \
    'luassert 1.9.0-1' 'mediator_lua 1.1.2-0' 'penlight 1.15.0-1' \
    'busted 2.2.0-1' 'luacheck 1.2.0-1' 'lua-cjson 2.1.0.10-1' 'lua-resty-http 0.17.2-0'; \
    do /usr/bin/luarocks install --deps-mode=none $rock || exit; done
WORKDIR /workspace
CMD ["bash"]

FROM dev AS build
ARG QJSON_REVISION
RUN test ${#QJSON_REVISION} = 40
COPY . /workspace
RUN cargo build --locked --release

FROM ${OPENRESTY_IMAGE} AS runtime
ARG QJSON_REVISION
LABEL org.opencontainers.image.source="https://github.com/GYWang1983/lua-qjson" \
    org.opencontainers.image.revision="${QJSON_REVISION}"
ENV LD_LIBRARY_PATH=/opt/qjson/lib
COPY --from=build /workspace/target/release/libqjson.so /opt/qjson/lib/libqjson.so
COPY --from=build /workspace/lua/ /opt/qjson/lua/
COPY --from=build /workspace/examples/openresty/ /opt/qjson/examples/
COPY --from=build /workspace/LICENSE /opt/qjson/LICENSE
COPY --from=build /usr/local/share/lua/5.1/resty/ /usr/local/openresty/site/lualib/resty/
RUN mkdir -p /tmp/qjson-body /tmp/qjson-logs/logs && chmod 777 /tmp/qjson-body /tmp/qjson-logs
EXPOSE 8080
CMD ["/usr/local/openresty/nginx/sbin/nginx", "-p", "/tmp/qjson-logs/", "-c", "/opt/qjson/examples/nginx.conf"]
