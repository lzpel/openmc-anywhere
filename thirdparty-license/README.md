# Third-party licenses

The `openmc-anywhere` wheels redistribute prebuilt binaries. This directory holds the
license of every redistributed component, copied verbatim from the revision pinned as a
submodule in this repository.

| File | Component | Version | License |
|:---|:---|:---|:---|
| `OpenMC-LICENSE` | [OpenMC](https://github.com/openmc-dev/openmc) | 0.15.3.post214 | MIT |
| `HDF5-LICENSE` | [HDF5](https://github.com/HDFGroup/hdf5) | 2.1.1 | BSD-3-Clause style |
| `DAGMC-LICENSE` | [DAGMC](https://github.com/svalinn/DAGMC) | 3.2.4 | BSD-2-Clause |
| `MOAB-LICENSE` | [MOAB](https://bitbucket.org/fathomteam/moab) | 5.6.0 | **LGPL-3.0-or-later** |
| `NJOY2016-LICENSE` | [NJOY2016](https://github.com/njoy/NJOY2016) | 2016.79 | BSD-3-Clause style (LANL) |
| `GPL-3.0-LICENSE` | [GNU GPL](https://www.gnu.org/licenses/gpl-3.0.txt) | 3.0 | referenced by MOAB's LGPL |

## MOAB and the LGPL-3.0

Every component except MOAB is permissive and asks only that these notices travel with the
distribution. MOAB is copyleft. It is statically linked into the `openmc` executable and
into `libopenmc`, which makes those binaries a Combined Work under LGPL-3.0. `GPL-3.0-LICENSE`
accompanies `MOAB-LICENSE` because LGPL-3.0 §4(b) requires both texts.

LGPL-3.0 §4(d) entitles you to relink the Combined Work against a modified version of MOAB.
This project satisfies that through §4(d)(0): the complete source of the Combined Work is
public, and running `make cross-<triple>` at the corresponding tag of
[this repository](https://github.com/lzpel/openmc-anywhere) rebuilds the binaries against a
MOAB of your choosing.

MOAB's license text lists TempestRemap (GPL) among its exceptions. These builds leave
`ENABLE_TEMPESTREMAP` off, so no GPL-licensed code is linked into the wheels.
