# OpenMC Anywhere

Monte Carlo Particle Transport Code with unofficial Windows/Apple/Linux pypi wheel.

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![PyPI](https://img.shields.io/pypi/v/openmc-anywhere.svg?color=green)](https://pypi.org/pypi/openmc-anywhere)

## What is OpenMC Anywhere

`openmc-anywhere` is an **unofficial** binary redistribution of upstream
[openmc-dev/openmc](https://github.com/openmc-dev/openmc). The distribution name is
`openmc-anywhere`; the import name is plain `openmc`, exactly as upstream.

- **Bundled**: the `openmc` Python package, the `openmc` executable that `Model.run()`
  invokes, `libopenmc.{dll,so,dylib}` that `openmc.lib` loads through ctypes, and `njoy`
  (NJOY2016) for converting ENDF files yourself.
- **Statically linked in**: HDF5, MOAB and DAGMC, plus the language runtimes. DAGMC and
  OpenMP shared-memory parallelism are enabled. No conda, no Docker, no source build, and
  nothing to install system-wide.
- **Not bundled**: cross-section data and depletion chains — point `OPENMC_CROSS_SECTIONS`
  at your own library as usual.
- **Not built**: MPI, libMesh, UWUW and PyMOAB are all disabled.

### Prebuilt wheel

| | Target | Wheel tag | OpenMC | HDF5 | DAGMC | MOAB | NJOY |
|:---:|:---|:---|:---|:---|:---|:---|:---|
| ![img](figure/linux.svg) | `x86_64-unknown-linux-gnu` | `manylinux_2_28_x86_64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |
| ![img](figure/linux.svg) | `aarch64-unknown-linux-gnu` | `manylinux_2_28_aarch64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |
| ![img](figure/windows.svg) | `x86_64-pc-windows-gnu` | `win_amd64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |
| ![img](figure/apple.svg) | `x86_64-apple-darwin` | `macosx_11_0_x86_64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |
| ![img](figure/apple.svg) | `aarch64-apple-darwin` | `macosx_11_0_arm64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |

Every target ships the same stack at the same versions, tagged `py3-none-<tag>` — the
Python package is pure Python, so the wheels do not depend on a CPython version. Linux
wheels target manylinux_2_28 (glibc 2.28+); macOS wheels target deployment target 11.0.
The **macOS wheels are experimental**: they are cross-built with osxcross and flang and
have not been verified on real hardware.

## Getting-started

```bash
$ cat main.py
import openmc

li = openmc.Material()
li.add_element("Li", 1.0)
li.set_density("g/cm3", 0.534)
sphere = openmc.Sphere(r=20.0, boundary_type="vacuum")
cell = openmc.Cell(fill=li, region=-sphere)

settings = openmc.Settings(run_mode="fixed source", batches=5, particles=10_000)
settings.source = openmc.IndependentSource(
    space=openmc.stats.Point(), energy=openmc.stats.Discrete([14.1e6], [1.0])
)
tally = openmc.Tally(name="tbr")
tally.filters = [openmc.CellFilter(cell)]
tally.scores = ["H3-production"]

model = openmc.Model(openmc.Geometry([cell]), openmc.Materials([li]), settings,
                     openmc.Tallies([tally]))
with openmc.StatePoint(model.run(output=False)) as sp:
    t = sp.get_tally(name="tbr")
    print(f"openmc {openmc.__version__}  TBR = {t.mean.item():.4f} +/- {t.std_dev.item():.4f}")

$ export OPENMC_CROSS_SECTIONS=/path/to/cross_sections.xml   # data is not bundled
$ pip install openmc-anywhere && python main.py
# or
$ uv add openmc-anywhere && uv run main.py

openmc 0.15.3.post214  TBR = 0.2683 +/- 0.0004
```

A 20 cm sphere of natural lithium driven by a 14.1 MeV point source: the tritium breeding
ratio comes out at 0.2683. The run above is the manylinux_2_28_x86_64 wheel executed in a
stock `python:3.12` container with nothing else installed.

Cross-section data is not bundled, so unpack one of the
[official OpenMC data libraries](https://openmc.org/official-data-libraries/) and point
`OPENMC_CROSS_SECTIONS` at its `cross_sections.xml`. Because `njoy` ships in the wheel you
can also produce the data yourself:

```python
openmc.data.IncidentNeutron.from_njoy("n-092_U_235.endf", temperatures=[300, 600, 900])
```

Besides PyPI, a PEP 503 simple index served from GitHub Pages points straight at the
GitHub Release assets. CI regenerates it from every `prebuilt` build, so it carries the
newest wheels first:

```toml
[tool.uv.sources]
openmc-anywhere = { index = "openmc-anywhere" }

[[tool.uv.index]]
name = "openmc-anywhere"
url = "https://lzpel.github.io/openmc-anywhere/wheel/"
```

Build instructions, design rationale and the measured reasoning behind every linker flag
live in [notes/20260723-openmc-anywhere設計と実装メモ.md](notes/20260723-openmc-anywhere設計と実装メモ.md)
(Japanese). This project was previously named `openmc-pypi`; the old Pages index URL
`https://lzpel.github.io/openmc-pypi/wheel/` is **gone and not redirected** — GitHub
forwards repository URLs but not Pages. See
[notes/20260723-openmc-anywhere改名の理由.md](notes/20260723-openmc-anywhere改名の理由.md).

## License

This repository's build tooling is MIT (see [LICENSE](./LICENSE)). The redistributed
components keep their own terms: OpenMC (MIT), HDF5 (BSD-3-Clause style), DAGMC
(BSD-3-Clause), NJOY2016 (LANL BSD-3-Clause style, shipped in the wheel's dist-info as
`NJOY2016-LICENSE`), and **MOAB (LGPL-3.0)**. MOAB is statically linked into the `openmc`
executable and into `libopenmc`, so redistributing these wheels carries the LGPL-3.0
obligations for a Combined Work.
