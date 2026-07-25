"""wheel にプラットフォームタグとバイナリを与えるビルドフック。

makefile が環境変数で全てを注入する (sys.platform 分岐を持たない。クロスビルドでは
ホスト OS とターゲット OS が食い違うため、ホスト検出はそもそも成立しない):

- OPENMC_ANYWHERE_PLAT:  wheel プラットフォームタグ (win_amd64 / linux_x86_64 /
  macosx_11_0_arm64 など。タグの正当性はビルド手順側の責任)。python パッケージは
  pure Python (ext_modules 無し) なので CPython バージョンに依存しない py3-none-<plat>。
- OPENMC_ANYWHERE_OUT:   per-target 出力ディレクトリ (out/<triple>/wheel。同階層の out/<triple>/*
  は cmake のビルドディレクトリ)。libopenmc と実行ファイルはここから拾う。上流 CMake の
  POST_BUILD はソースツリー openmc/lib/ にコピーするが、そこは全 TARGET 共有で同 OS の
  2 arch (linux の x86_64/aarch64 など) が同名衝突するため、makefile が退避したコピーを
  正とする。pyproject の exclude (*.a *.dll *.so *.dylib) がソースツリー側の残骸を一括で
  締め出し、force_include (exclude より優先) が正しい1つだけを戻す。
- OPENMC_ANYWHERE_SOEXT: 共有ライブラリ拡張子 (dll / so / dylib)。dll なら実行ファイルは .exe。
- OPENMC_ANYWHERE_NJOY:  njoy 実行ファイルのパス。未設定なら njoy 無し wheel (darwin の
  flang クロスが通らない場合の逃げ道。WITH_NJOY=0)。

openmc / njoy 実行ファイルは shared_scripts で wheel の .data/scripts/ に入れる。pip/uv が
venv の Scripts (bin) に配置するので、上流 executor.py の PATH 解決 (literal 'openmc') と
openmc/data/njoy.py の Popen(['njoy']) が無改造で通る。
NJOY2016 の LICENSE (LANL の BSD-3 系、告知同梱で再配布可) を dist-info に同梱する。
"""

import os

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        build_data["tag"] = f"py3-none-{os.environ['OPENMC_ANYWHERE_PLAT']}"
        build_data["pure_python"] = False
        out = os.environ["OPENMC_ANYWHERE_OUT"]
        suffix = os.environ["OPENMC_ANYWHERE_SOEXT"]
        exe_ext = ".exe" if suffix == "dll" else ""
        lib = f"{out}/libopenmc.{suffix}"
        exe = f"{out}/openmc{exe_ext}"
        njoy = os.environ.get("OPENMC_ANYWHERE_NJOY")
        missing = [p for p in (lib, exe, njoy) if p and not os.path.exists(p)]
        if missing:
            raise FileNotFoundError(f"run 'make wheel' first: missing {missing}")
        build_data["force_include"][lib] = f"openmc/lib/libopenmc.{suffix}"
        build_data["shared_scripts"] = {exe: os.path.basename(exe)}
        if njoy:
            build_data["shared_scripts"][njoy] = os.path.basename(njoy)
            build_data["extra_metadata"] = {"src/njoy/LICENSE": "NJOY2016-LICENSE"}
