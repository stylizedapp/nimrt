# Vendored QuickJS

This directory contains a vendored copy of the **QuickJS Javascript Engine** used by `src/nimui/js/` (compiled into `src/nimui/js/libquickjs.a` alongside `src/nimui/js/qjs_bridge.c` via [`tools/build_quickjs.ps1`](../../../../tools/build_quickjs.ps1)).

## Provenance

- **Version:** `2026-06-04` (from [`VERSION`](VERSION))
- **Upstream Repository:** `https://bellard.org/quickjs/` / `https://github.com/bellard/quickjs`
- **Upstream Commit:** Not recorded in this vendored snapshot (imported in repository commit `5a6aa00` from the `2026-06-04` release/snapshot; [`LICENSE`](LICENSE) and [`quickjs.h`](quickjs.h) carry `Copyright (c) 2017-2021 Fabrice Bellard` / `Charlie Gordon`, and [`quickjs.c`](quickjs.c) carries `Copyright (c) 2017-2025 Fabrice Bellard` / `Charlie Gordon`).
- **License:** MIT (see [`LICENSE`](LICENSE))

## Vendored Files & SHA256 Checksums

| File | Size (bytes) | SHA256 |
| :--- | ---: | :--- |
| `LICENSE` | 1152 | `2f2a9e35fbaa43435fad0cb8253a1f1d284282ba75b9ce5988bb9b10a5eac94f` |
| `VERSION` | 12 | `c8e0b2c47552fb218d2d7ac56c60be2d2cf9a3b567223e9477a8eb2423755ad2` |
| `cutils.c` | 18439 | `406fa69b7262e6a66df9594acbc619ba973668f37086b4acbaf3ef486776582a` |
| `cutils.h` | 11619 | `2728d27c361d2f13df45550e549e2a3ead9e1326396a54e7dcd1737cf9628afb` |
| `dtoa.c` | 46495 | `bed2995924a6427a065e75e924a5ea6f8a9cbba3b53a857f25dfd28a2138c1b1` |
| `dtoa.h` | 3389 | `964ab3aa8abb307818fd4450f0159994da15d9aa2ee51db1a4dbbbeb8a4872cc` |
| `libregexp-opcode.h` | 2960 | `00701bc29a1db2bd82cb965530204a08b9e193edebe1a15247b13b4a6ff28f07` |
| `libregexp.c` | 116679 | `51fab931dbc494d6135e3650a17f49f904ddd55bc7393fa141e73a355483d8bc` |
| `libregexp.h` | 2802 | `255be608b75a2eaf5695daf655030c411906fd4f459930cac07031b59259a3fb` |
| `libunicode-table.h` | 257898 | `0cb777e039734b6a5735fdc73a13859b1a54f9f3a8698dadf0d6d50ed80995fc` |
| `libunicode.c` | 65975 | `96bad04b0a4b254a43e6dbde60ab2f1cf4bd2dd0d37c4a0a7247b11fcd07108b` |
| `libunicode.h` | 6245 | `c4251c645bbd34b32ef352de9e018e565c1b83476ffdabef7a0074fbabd6f26d` |
| `list.h` | 3188 | `158d26196fcd1da2d57c38aac5830f4512f4b567d4b3a220052223d75a7bd0c7` |
| `quickjs-atom.h` | 8924 | `6a955f22c4acf2a1e712d094c4dfee61b61c919318aab33394c93239411660dd` |
| `quickjs-opcode.h` | 16433 | `c6773f5408925805b36b5d8dd054605719f415a062aee39964936b9e88d8cc04` |
| `quickjs.c` | 2253579 | `bee774e6730ea89b6f77447ce78db58a60ab8b095c40161aeba281dac3eaf002` |
| `quickjs.h` | 54110 | `a389522b35e0049ee97fb54bd88bd9d4eb67ba61f28bef65af28124b5b8dfa70` |
