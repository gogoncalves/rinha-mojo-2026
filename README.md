rinha de backend 2026 em mojo.

ivf k=4096 nprobe=2 com early-exit, repair_fast + repair_full bbox-lb. simd
nativo via SIMD[DType.int16, 16], soa pair-packed. scm_rights fd-passing
lb. epoll edge-triggered.

build (requer mojo 1.0.0b1):

```
pixi global install -c https://conda.modular.com/max -c conda-forge mojo
export MODULAR_HOME=$HOME/.pixi/envs/mojo/share/max  # pixi global precisa disso
make smoke    # SIMD self-test (roda nativo macOS/Linux)
make build    # api + lb (linka so em linux: usa epoll/scm_rights)
docker compose up -d
```

## Mojo 1.0.0b1 - quirks que esse repo encontrou

A b1 (abril 2026) eh a primeira beta; a documentacao pre-1.0 esta
desatualizada. Os arquivos em `src/` cobrem todos os bugs/migracoes que a
gente bateu durante o port do Zig v31:

| Padrao antigo | Substituicao b1 |
|---|---|
| `alias FOO = 42` | `comptime FOO = 42` |
| `@parameter for i in range(N)` | `comptime for i in range(N)` |
| `fn f(...)` | `def f(...)` |
| `from sys.ffi import external_call` | `@extern("sym") def ... abi("c")` |
| `from sys.info import os_is_linux` | removido - assumir linux no Dockerfile |
| `@register_passable("trivial")` | `struct S(TrivialRegisterPassable)` |
| `UnsafePointer[T]` | `UnsafePointer[T, origin=MutExternalOrigin]` |
| `UnsafePointer[T]()` (null) | `UnsafePointer[T,o].unsafe_dangling()` |
| `UnsafePointer[T].alloc(n)` | `libc_malloc(n).bitcast[T]()` via `@extern` |
| `simd.bitcast[...]()` metodo | `bitcast` free function de `std.memory` |
| `simd.max(other)` metodo | `max(a, b)` builtin |
| `simd_a >= simd_b` | `simd_a.ge(simd_b)` (retorna SIMD[bool, N]) |
| `StaticTuple[T, N]` | `InlineArray[T, N]` (ou hand-rolled) |
| `String[i]` | `String[byte=i]` |
| `len(s)` em `String`/`StaticString` | `s.byte_length()` |
| `memcpy(dest, src, n)` posicional | `memcpy(dest=d, src=s, count=n)` keyword-only |
| `buf[i] == ord("x")` | `buf[i] == UInt8(ord("x"))` (implicit conv removido) |
| `from memory import X` | `from std.memory import X` (path completo) |
| `out` parametro renomeado | use `dst` ou outro nome (`out` virou keyword) |
| `UnsafePointer(to=buf[0])` em fn lib | use `buf.unsafe_ptr()` + `rebind[...]()` para origin |

Para coercer entre origins, use `rebind[UnsafePointer[T, origin=MutExternalOrigin]](ptr)`.
A b1 nao expoe `origin_cast()` nem `address_space_cast()` no UnsafePointer
publico ainda.

### Compiler crashes da b1 que precisaram workaround

Durante o port encontramos tres situacoes em que `mojo build` segfaulta
silenciosamente em vez de emitir um erro:

1. **`std.os.abort()` apos uma extern call** - substituido por um
   `die(msg)` local que faz `print(msg); libc_exit(1)`. Veja `index_bin.mojo`.

2. **`Int(unsafe_pointer)` quando o pointer vem de `mmap()` cross-module e
   eh comparado a `-1`** - solucao: pular o `MAP_FAILED` check; segfault
   em runtime se mmap falhar eh aceitavel. Vide nota em `open_index`.

3. **Funcoes que retornam structs e contem extern calls + InlineArray-
   based ABI buffers** - solucao: anotar com `@always_inline` para forcar
   inlining no caller. Aplicado em `open_index`, `score`, `bind_*`,
   `epoll_*`, e helpers de `main.mojo`.

`MODULAR_HOME` precisa apontar pra `share/max` no env do pixi para o
driver achar `std.mojopkg` e `libKGENCompilerRTShared.dylib`. Sem isso o
build morre com "unable to locate module 'std'".

## Arquivos

| File | Role |
|---|---|
| `src/main.mojo`         | API binary: epoll + SCM_RIGHTS fd-recv + HTTP keep-alive |
| `src/lb.mojo`           | LB binary: TCP :9999 → round-robin SCM_RIGHTS para api UDS |
| `src/index_bin.mojo`    | mmap + parse `index.bin`, `score(idx, q)` |
| `src/knn.mojo`          | SIMD kernels: `quantize`, `blk_dist`, `blk_dist_prune`, `bbox_lower_bound`, probe heap |
| `src/normalize.mojo`    | 14-dim `vectorize(Payload)`, MCC risk lookup |
| `src/json_parse.mojo`   | Hand-rolled JSON parser (zero-alloc, slices em request buf) |
| `src/time_utils.mojo`   | RFC3339 → Stamp + epoch seconds + day-of-week |
| `src/http_io.mojo`      | Request parsing + canned response table |
| `src/smoke.mojo`        | Sanity test do SIMD kernel (roda em qualquer host) |
| `tools/build_index.zig` | Offline indexer (mesmo do Zig v31) |

## SMOKE output

```
$ make smoke
mojo build -I src -O 3 src/smoke.mojo -o smoke
./smoke
block dist lane0 = 56
block dist lane7 = 56
bbox lb = 56
```
