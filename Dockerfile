
FROM --platform=linux/amd64 debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates xz-utils tar gzip build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://pixi.sh/install.sh | bash \
    && ln -s /root/.pixi/bin/pixi /usr/local/bin/pixi

RUN pixi global install \
        -c https://conda.modular.com/max \
        -c conda-forge \
        mojo \
    && ln -s /root/.pixi/envs/mojo/bin/mojo /usr/local/bin/mojo

WORKDIR /src

ARG INDEX_BIN_PATH=/index.bin
COPY tools ./tools

ARG REFERENCES_URL=https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/references.json.gz
RUN if [ -f tools/build_index.zig ]; then \
        apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
        curl -fsSL "https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz" \
            | tar -xJ -C /opt && \
        ln -s /opt/zig-x86_64-linux-0.14.1/zig /usr/local/bin/zig && \
        mkdir -p zig-out && \
        zig build-exe -O ReleaseFast -lc -fstrip \
            -target x86_64-linux-musl -mcpu haswell \
            -femit-bin=zig-out/build-index tools/build_index.zig && \
        curl -fsSL -o /tmp/refs.json.gz "${REFERENCES_URL}" && \
        gunzip /tmp/refs.json.gz && \
        INPUT=/tmp/refs.json OUTPUT=${INDEX_BIN_PATH} /src/zig-out/build-index && \
        rm /tmp/refs.json; \
    fi

COPY src ./src

RUN gcc -O2 -c -o /src/trace_shim.o /src/src/trace_shim.c

# v7: LB is now pure C (ported from rival lucasmontano lb_c.c).
# Static link so the runtime stage does not need any C runtime beyond what's already there.
RUN gcc -O3 -static -Wall -Wextra -o /src/lb /src/src/lb.c

ENV MODULAR_HOME=/root/.pixi/envs/mojo/share/max
RUN mojo build src/main.mojo -I src -O 3 -Xlinker /src/trace_shim.o -o /src/api

FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libc6 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /root/.pixi/envs/mojo/lib/libKGENCompilerRTShared.so /usr/local/lib/
COPY --from=builder /root/.pixi/envs/mojo/lib/ /opt/mojo/lib/
ENV LD_LIBRARY_PATH=/usr/local/lib:/opt/mojo/lib
RUN ldconfig

COPY --from=builder /src/api /api
COPY --from=builder /src/lb  /lb
COPY --from=builder /index.bin /data/index.bin
ENV INDEX_PATH=/data/index.bin
EXPOSE 9999
ENTRYPOINT ["/api"]
