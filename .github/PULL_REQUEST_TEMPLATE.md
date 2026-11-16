## Description

<!-- Provide a brief description of the problem solved, feature added, or optimization made. -->

## Type of Change

- [ ] 🐛 Bug fix (non-breaking change which fixes an issue)
- [ ] ✨ New feature (non-breaking change which adds functionality)
- [ ] ⚡ Performance optimization (AlgX, CoreX, GPU, or layout speedups)
- [ ] 🛡️ Memory safety / verification (`nim_safe`, ATF C-checker, leak tests)
- [ ] 📚 Documentation & examples update
- [ ] 🔧 Tooling, CI, or build system improvements

## Subsystems Affected

- [ ] `src/corex` (Memory allocators, concurrency, platform, signals)
- [ ] `src/algx` (UltraSort, FastMap, ZeroPack, SimdScan)
- [ ] `src/nimui` (Flexbox layout, widgets, HTML5/CSS3 parser & cascade, Vulkan SDF)
- [ ] `src/nimui/js` (QuickJS bridge, sandbox validator)
- [ ] `compiler/` (`nim_safe`, ATF C checker)
- [ ] `apps/` (Studio, Desktop, Widget Gallery, Singularity Demo, WizTree)

## Verification Checklist

Please verify before requesting review:

- [ ] My code adheres to the project guidelines: `--mm:orc --threads:on --panics:on` compatible.
- [ ] I have verified **zero memory leaks** (`testWithLeakCheck` for allocators, ORC delta check).
- [ ] All unit and integration tests pass locally (`nimble test_all`).
- [ ] Zero compiler warnings with strict flags (`nim check --warningAsError[UnusedImport]:on ...`).
- [ ] Any new UI features or widgets work in headless tests (`nimble test_showcase`).
- [ ] If changing shaders, SPIR-V bytecode and `src/nimui/gpu/shaders.nim` are regenerated.
- [ ] Relevant documentation in `README.md` or `docs/` has been updated.

## Screenshots or Benchmark Output (if applicable)

<!-- Add screenshots for UI changes or benchmark numbers for performance PRs -->
