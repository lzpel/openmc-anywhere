#!/usr/bin/env python3
"""openmc-anywhere wheel の検証。wheel をインストールした venv で実行する。

核データ (cross_sections.xml / ENDF テープ) を一切必要としない経路だけに絞る。この wheel の
責務は「公式 OpenMC のバイナリが3 OS でそのまま動く」ことなので、検証すべきは同梱バイナリが
ロード・起動でき、意図した機能フラグで組まれていること。輸送計算の物理的な正しさは上流
OpenMC の回帰テストの責務であって、ここで断面積を持ち込んで再確認する価値は無い。

5経路を通す:
  (a) exe:   PATH 上の openmc(.exe) が --version で起動し、build info の DAGMC が yes
  (b) lib:   openmc.lib の import で同梱 libopenmc.{dll,so,dylib} が CDLL でロードされ、
             DAGMC/UWUW/libMesh の各フラグが build.py の cmake 指定と一致する
  (c) model: 核データ不要の範囲の Python API (材料・幾何・タリー → model.xml 書き出し)
  (d) dagmc: 引数に .h5m を渡すとトポロジを検査 (上流 legacy テストモデルで 5 cells / 21 surfaces)
  (e) njoy:  同梱 njoy が空デッキ (stop カードのみ) で起動して正常終了する

生成物 (model.xml, njoy の output 等) はカレントに落ちるので使い捨てディレクトリで実行する
(build.py の check がそうしている)。
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import openmc
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

    return openmc.Model(
        openmc.Geometry([cell]), openmc.Materials([li]), settings, openmc.Tallies([tally])
    )


def run(argv, **kwargs):
    """実行ファイルを起動して stdout を返す。失敗は出力ごと表示して落とす。"""
    p = subprocess.run(argv, capture_output=True, text=True, **kwargs)
    if p.returncode != 0:
        sys.exit(f"{argv[0]} exited {p.returncode}\n--- stdout ---\n{p.stdout}\n"
                 f"--- stderr ---\n{p.stderr}")
    return p.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("h5m", nargs="?", help="DAGMC legacy test model (optional)")
    args = parser.parse_args()

    print(f"openmc {openmc.__version__}")

    # (a) 実行ファイル経路。--version は openmc_init が -1 を返して main が 0 で抜ける
    # (upstream src/main.cpp) ので、断面積が無くても起動と動的依存の解決を確認できる。
    # 上流 executor.py と同じく literal 'openmc' を PATH から解決させる。
    exe = shutil.which("openmc")
    if exe is None:
        sys.exit("openmc executable not found on PATH")
    info = run([exe, "--version"])
    build_info = dict(
        (k.strip(), v.strip())
        for k, _, v in (line.partition(":") for line in info.splitlines()) if k and v
    )
    print(f"(a) exe: {exe} DAGMC={build_info.get('DAGMC support')}")
    assert build_info.get("DAGMC support") == "yes", info

    # (b) 共有ライブラリ経路。これらは in_dll の定数読み出しなので openmc.lib.init() 不要
    # (upstream openmc/lib/__init__.py)。build.py の cmake 指定と1対1で突き合わせる。
    flags = {
        "dagmc": openmc.lib._dagmc_enabled(),    # -DOPENMC_USE_DAGMC=ON
        "uwuw": openmc.lib._uwuw_enabled(),      # -DOPENMC_USE_UWUW=OFF
        "libmesh": openmc.lib._libmesh_enabled(),  # -DOPENMC_USE_LIBMESH=OFF
    }
    print(f"(b) lib: {openmc.lib._filename} {flags}")
    assert flags == {"dagmc": True, "uwuw": False, "libmesh": False}, flags

    # (c) Python API。材料の元素展開も XML 書き出しも核データを読まない
    # (Materials.export_to_xml の <cross_sections> は未設定なら省略される)。
    build_model().export_to_model_xml()
    xml = Path("model.xml").read_text()
    print(f"(c) model: model.xml {len(xml)} bytes")
    assert "H3-production" in xml and "lithium" in xml

    # (d) DAGMC トポロジ (h5py で .h5m を直接読む経路、openmc.lib 不要)
    if args.h5m:
        u = openmc.DAGMCUniverse(args.h5m)
        print(f"(d) dagmc: n_cells={u.n_cells} n_surfaces={u.n_surfaces}")
        assert (u.n_cells, u.n_surfaces) == (5, 21)

    # (e) njoy。モジュール名 'stop' だけのデッキで main のループが即 exit する
    # (upstream src/main.f90)。ENDF テープ無しで起動と動的依存の解決だけを確認する。
    njoy = shutil.which("njoy")
    if njoy is None:
        sys.exit("njoy executable not found on PATH")
    run([njoy], input="stop\n")
    print(f"(e) njoy: {njoy} ran empty deck")

    print("all checks passed")


if __name__ == "__main__":
    main()
