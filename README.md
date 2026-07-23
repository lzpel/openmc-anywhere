# OpenMC Anywhere

Monte Carlo Particle Transport Code with unofficial Windows/Apple/Linux pypi wheel.

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![PyPI](https://img.shields.io/pypi/v/openmc-anywhere.svg?color=green)](https://pypi.org/pypi/openmc-anywhere)

## What is OpenMC Anywhere

This is an unofficial binary redistribution of upstream [openmc-dev/openmc](https://github.com/openmc-dev/openmc).
The distribution name is openmc-anywhere; the import name is plain `openmc`, exactly as upstream.

### Prebuilt wheel

| | Target | Wheel tag | OpenMC | HDF5 | DAGMC | MOAB | NJOY |
|:---:|:---|:---|:---|:---|:---|:---|:---|
| ![img](figure/linux.svg) | `x86_64-unknown-linux-gnu` | `manylinux_2_28_x86_64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |
| ![img](figure/linux.svg) | `aarch64-unknown-linux-gnu` | `manylinux_2_28_aarch64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |
| ![img](figure/windows.svg) | `x86_64-pc-windows-gnu` | `win_amd64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |
| ![img](figure/apple.svg) | `x86_64-apple-darwin` | `macosx_11_0_x86_64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |
| ![img](figure/apple.svg) | `aarch64-apple-darwin` | `macosx_11_0_arm64` | 0.15.3.post214 | 2.1.1 | 3.2.4 | 5.6.0 | 2016.79 |

## Getting-started

```python:main.py
import openmc
# A 20 cm sphere of natural lithium driven by a 14.1 MeV point source: the tritium breeding ratio comes out at 0.2683.
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

model = openmc.Model(openmc.Geometry([cell]), openmc.Materials([li]), settings, openmc.Tallies([tally]))
with openmc.StatePoint(model.run(output=False)) as sp:
    t = sp.get_tally(name="tbr")
    print(f"openmc {openmc.__version__}  TBR = {t.mean.item():.4f} +/- {t.std_dev.item():.4f}")
```

```bash
$ export OPENMC_CROSS_SECTIONS=/path/to/cross_sections.xml   # data is not bundled
$ pip install openmc-anywhere && python main.py
# or
$ uv add openmc-anywhere && uv run main.py

openmc 0.15.3.post214  TBR = 0.2683 +/- 0.0004
```

```python
openmc.data.IncidentNeutron.from_njoy("n-092_U_235.endf", temperatures=[300, 600, 900])
```

```toml
[tool.uv.sources]
openmc-anywhere = { index = "openmc-anywhere" }

[[tool.uv.index]]
name = "openmc-anywhere"
url = "https://lzpel.github.io/openmc-anywhere/wheel/"
```

## License

This repository's build tooling is MIT (see [LICENSE](./LICENSE)). The redistributed
components keep their own terms: OpenMC (MIT), HDF5 (BSD-3-Clause style), DAGMC
(BSD-3-Clause), NJOY2016 (LANL BSD-3-Clause style, shipped in the wheel's dist-info as
`NJOY2016-LICENSE`), and **MOAB (LGPL-3.0)**. MOAB is statically linked into the `openmc`
executable and into `libopenmc`, so redistributing these wheels carries the LGPL-3.0
obligations for a Combined Work.
