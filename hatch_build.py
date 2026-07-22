"""wheel にプラットフォームタグとバイナリを与えるビルドフック。

- タグ: python パッケージは pure Python (ext_modules 無し) なので CPython バージョンに
  依存しない py3-none-<plat>。<plat> は makefile が OPENMC_PYPI_PLAT で注入する
  (win_amd64 / manylinux_2_28_x86_64 など。タグの正当性はビルド手順側の責任)。
- libopenmc.{dll,so}: 上流 CMake の POST_BUILD がソースツリー openmc/lib/ にコピーする。
  pyproject の exclude (*.a *.dll *.so) がビルド産物を一括で締め出しているので、
  現プラットフォームの1つだけを force_include (exclude より優先) で戻す。Windows と Linux が
  同じ submodule ツリーを共有するため、反対側のライブラリの残骸を拾わないための構成。
- openmc 実行ファイル: shared_scripts で wheel の .data/scripts/ に入れる。pip/uv が venv の
  Scripts (bin) に配置するので、上流 executor.py の PATH 解決 (literal 'openmc') が無改造で通る。
"""

import os
import sys

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        build_data["tag"] = f"py3-none-{os.environ['OPENMC_PYPI_PLAT']}"
        build_data["pure_python"] = False
        if sys.platform == "win32":
            suffix, exe = "dll", "out/windows/openmc.exe"
        else:
            suffix, exe = "so", "out/linux/openmc"
        lib = f"src/openmc/openmc/lib/libopenmc.{suffix}"
        if not os.path.exists(lib) or not os.path.exists(exe):
            raise FileNotFoundError(f"run 'make openmc-exe openmc-lib' first: missing {lib} or {exe}")
        build_data["force_include"][lib] = f"openmc/lib/libopenmc.{suffix}"
        build_data["shared_scripts"] = {exe: os.path.basename(exe)}
