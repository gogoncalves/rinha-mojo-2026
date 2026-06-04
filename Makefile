.PHONY: smoke api lb build clean docker test

MOJO ?= mojo
MOJO_FLAGS ?= -I src -O 3

# Mojo 1.0.0b1 (pixi global install) needs MODULAR_HOME pointed at
# share/max in the environment root so it can locate std.mojopkg and
# the compiler runtime libs. Without this 'mojo build' bails with
# "unable to locate module 'std'".
export MODULAR_HOME ?= $(HOME)/.pixi/envs/mojo/share/max

smoke:
	$(MOJO) build $(MOJO_FLAGS) src/smoke.mojo -o smoke
	./smoke

api:
	$(MOJO) build $(MOJO_FLAGS) src/main.mojo -o api

lb:
	$(MOJO) build $(MOJO_FLAGS) src/lb.mojo -o lb

build: api lb

docker:
	docker buildx build --platform=linux/amd64 -t rinha-2026-fraud-mojo:dev .

clean:
	rm -f api lb smoke *.o
