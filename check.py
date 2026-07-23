#!/usr/bin/env python3
"""openmc-anywhere wheel の end-to-end 検証。wheel をインストールした venv で実行する。

4経路を通す:
  (a) subprocess: Model.run() が PATH 上の openmc(.exe) を起動し statepoint を読む
  (b) in-memory: openmc.lib (同梱 libopenmc.{dll,so} の ctypes) で run/tallies/cells/hard_reset
  (c) DAGMC: 引数に .h5m を渡すとトポロジを検査 (上流 legacy テストモデルで 5 cells / 21 surfaces)
  (d) njoy: --endf を渡すと from_njoy で ENDF→HDF5 変換 (同梱 njoy 実行ファイルの
      reconr/broadr/heatr×2/gaspr/purr/acer をエンドツーエンドで通す)

OPENMC_CROSS_SECTIONS が設定済みであること。生成物 (xml, statepoint 等) はカレントに落ちるので
使い捨てディレクトリで実行する (build.py の check がそうしている)。
"""

import argparse

import openmc
import openmc.data
# 関数内で import すると `openmc` が関数ローカル名になり、それ以前の openmc.* 参照が
# UnboundLocalError になるため module レベルで読む (DLL のロードもここで起きる)
import openmc.lib


def build_model():
    li = openmc.Material(name="lithium")
    li.add_element("Li", 1.0)
    li.set_density("g/cm3", 0.534)
    sphere = openmc.Sphere(r=20.0, boundary_type="vacuum")
    cell = openmc.Cell(fill=li, region=-sphere)

    settings = openmc.Settings()
    settings.run_mode = "fixed source"
    settings.batches = 5
    settings.particles = 10_000
    src = openmc.IndependentSource()
    src.space = openmc.stats.Point((0, 0, 0))
    src.energy = openmc.stats.Discrete([14.1e6], [1.0])
    settings.source = src

    tally = openmc.Tally(name="tbr")
    tally.filters = [openmc.CellFilter(cell)]
    tally.scores = ["H3-production"]

    model = openmc.Model(
        openmc.Geometry([cell]), openmc.Materials([li]), settings, openmc.Tallies([tally])
    )
    return model, tally


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("h5m", nargs="?", help="DAGMC legacy test model (optional)")
    parser.add_argument("--endf", help="ENDF file for the from_njoy smoke test (optional)")
    args = parser.parse_args()

    print(f"openmc {openmc.__version__}")
    model, tally = build_model()

    # (a) subprocess 経路
    sp_path = model.run(output=False)
    with openmc.StatePoint(sp_path) as sp:
        t = sp.get_tally(name="tbr")
        tbr = t.mean.item()
        print(f"(a) subprocess route: TBR = {tbr:.4f} +/- {t.std_dev.item():.4f}")
    assert tbr > 0

    # (b) in-memory 経路
    model.export_to_model_xml()
    with openmc.lib.run_in_memory():
        assert openmc.lib._dagmc_enabled(), "DAGMC support missing in libopenmc"
        openmc.lib.run()
        tbr_lib = openmc.lib.tallies[tally.id].mean.item()
        print(f"(b) in-memory route: TBR = {tbr_lib:.4f}")
        assert tbr_lib > 0
        assert len(openmc.lib.cells) == 1
        openmc.lib.hard_reset()

    # (c) DAGMC トポロジ (h5py で .h5m を直接読む経路、openmc.lib 不要)
    if args.h5m:
        u = openmc.DAGMCUniverse(args.h5m)
        print(f"(c) dagmc: n_cells={u.n_cells} n_surfaces={u.n_surfaces}")
        assert (u.n_cells, u.n_surfaces) == (5, 21)

    # (d) 同梱 njoy による ENDF→HDF5 変換 (293.6 K は "294K" グループに丸められる)
    if args.endf:
        nuc = openmc.data.IncidentNeutron.from_njoy(args.endf, temperatures=[293.6])
        print(f"(d) njoy: {nuc.name} temperatures={nuc.temperatures}")
        assert "294K" in nuc.temperatures

    print("all checks passed")


if __name__ == "__main__":
    main()
