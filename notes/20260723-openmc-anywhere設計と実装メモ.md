# openmc-anywhere 設計と実装メモ

README を英語の紹介に絞ったので、ビルド手順・設計判断・実測の根拠はここに置く。

## wheel に入っているもの

| もの | 置き場所 | 役割 |
|---|---|---|
| openmc python パッケージ | `openmc/` | 上流 `src/openmc/openmc` そのまま (+ 下記パッチ) |
| `openmc(.exe)` | wheel の `.data/scripts/` → venv の `Scripts`/`bin` | `Model.run()` が PATH で見つける実行ファイル。ランタイム込み静的リンクで自己完結 |
| `libopenmc.{dll,so}` | `openmc/lib/` | `openmc.lib` (ctypes) がロードする共有ライブラリ。同じく自己完結 |
| `njoy(.exe)` | 同じく `.data/scripts/` | `IncidentNeutron.from_njoy()` が Popen(['njoy']) で起動する NJOY2016 (2016.79)。自己完結 |

HDF5 / MOAB / DAGMC は exe と共有ライブラリの中に静的リンク済み (DAGMC 有効)。
NJOY2016 のライセンス (LANL の BSD-3 系。告知同梱でバイナリ再配布可) は wheel の
dist-info に `NJOY2016-LICENSE` として同梱している。

## ビルド

```
make cross-<triple>  # docker/Dockerfile_<triple> の toolchain イメージ内で wheel をビルド
                     #   (x86_64|aarch64)-unknown-linux-gnu … manylinux_2_28
                     #   (x86_64|aarch64)-apple-darwin      … osxcross クロス (実験的)
                     #   x86_64-pc-windows-gnu              … mingw-w64 クロス
make check-linux     # 素の python:3.12 コンテナで Linux wheel を検証 (可搬性の証明)
make check           # cross で作った wheel をホストの venv に入れて end-to-end 検証
make <stage>         # 段だけ回す (src hdf5 moab dagmc njoy openmc-exe openmc-lib wheel)
```

wheel は全 TARGET を Docker クロスで作る。ホストのネイティブビルド経路は持たない
(Windows の MSYS2 ネイティブビルドは実証済みだが CI 化に失敗したため廃止した。
ビルド手順そのものは mhd-tbr-stell/sandbox-openmc-source からの移植で、HDF5/MOAB/DAGMC の
バージョンピンと CMake フラグの根拠はそちらのコメントに詳しい)。

責務は3層に分かれる:

| 層 | 置き場 | 持つもの |
|---|---|---|
| 環境の事実 | `docker/Dockerfile_<triple>` の ENV | コンパイラ名・SDK・toolchain (`CC`/`CXX`/`FC`/`OTOOL`/`CMAKE_TOOLCHAIN_FILE`/`OPENMP_*`) |
| 段取りと方針 | `build.py` | 段の依存・cmake フラグ・リンク方針 (`PLAT`/`RUNTIME_STATIC`/...)・自己完結の断言 |
| メニュー | `makefile` | docker と gh の呼び出しだけ (94行) |

`build.py` の方針値はすべて同名の環境変数で上書きできるので、新しい toolchain を
試すときに `build.py` を書き換えなくてよい。darwin の Fortran (NJOY) は LLVM flang の
クロスで、通らない環境では `WITH_NJOY=0` で njoy 無し wheel に逃げられる。

## CI/CD (prebuilt ブランチ)

`prebuilt` ブランチへ push すると .github/workflows/prebuilt.yml が全5 TARGET
(linux x86_64/aarch64、darwin x86_64/aarch64、windows x86_64) の wheel をビルドし、
Release v<version> (pyproject.toml の version) に asset としてまとめて添付する。
既存の pages workflow が PEP 503 simple index を再生成する (GITHUB_TOKEN で作った
Release は release イベントを発火しないため、workflow_dispatch で明示起動している)。
手動の `make release` は逃げ道として残っている。

## 設計判断と根拠

- **exe と DLL は別ビルドディレクトリ**: MinGW は DLL の全シンボルを自動エクスポートするため、
  ランタイム静的リンクの exe を同じ DLL にリンクすると `_Unwind_Resume` が二重定義になる
  (sandbox-openmc-source で実測)。exe は libopenmc 静的 (`OPENMC_STATIC_LIB=ON` パッチ) で
  自己完結、共有ライブラリは `--target libopenmc` のみビルドして exe をリンクしない。
  問題を構造的に消す代わりにコンパイルは約2倍。
- **wheel タグは `py3-none-<plat>`**: python パッケージは pure Python (ext_modules 無し) で、
  バイナリは ctypes / subprocess でしか触らないので CPython バージョンに依存しない。
  タグは hatch_build.py が `OPENMC_ANYWHERE_PLAT` (build.py が注入) から組む。
- **Linux は manylinux_2_28 コンテナ + auditwheel repair**: exe は静的 libgomp で glibc のみに
  依存 (ldd で断言)。共有 lib は gcc-toolset の `libgomp.a` が非 PIC で .so に畳めない (実測:
  TLS 再配置 R_X86_64_TPOFF32 でリンク失敗) ため動的 libgomp のままにし、素の linux_x86_64
  タグで wheel を作ってから `auditwheel repair` が `libgomp.so.1` を同梱・manylinux_2_28 に
  retag する。
- **`.so` は `-Wl,--exclude-libs,ALL` が必須**: 静的リンクした HDF5/MOAB/pugixml/fmt の
  シンボルを .so からエクスポートすると、同一プロセスの h5py が持つ別ビルドの HDF5 と
  ELF のシンボル介入が起きて `openmc_init` が segfault する (実測: h5py を import しない
  プロセスでは同じ .so が正常動作)。Windows の DLL は介入が構造的に無いので不要。
- **Linux 固有のリンク調整**: FindHDF5 は既定で .so を探すので `HDF5_USE_STATIC_LIBRARIES=ON`
  が要る (MinGW は .a が import-lib 拡張子でもあるため偶然通る)。また CMake のリンク行が
  `...libhdf5.a ... libMOAB.a` の順になり、単一パスの ld では MOAB の mhdf が使う deprecated
  API (H5Aopen_name 等) だけ未解決になるため、`CMAKE_CXX_STANDARD_LIBRARIES` で HDF5 を
  リンク行末尾に再掲して閉じる。
- **上流は全部 submodule + パッチ**: `src/openmc` (openmc-dev/openmc の pin。
  v0.15.3-214-g54b661d39、M_PI 修正 [openmc#4023] 込み) に加え、`src/hdf5` (2.1.1) /
  `src/moab` (5.6.0) / `src/dagmc` (v3.2.4) / `src/njoy` (2016.79) も submodule
  (openmc だけは full clone: タグが CMake の GetVersionFromGit に必要。moab は配布 tarball
  が壊れているため git 必須)。パッチは `src/<component>-<name>.patch` にフラットに置き、
  ファイル名の最初の `-` より前が当て先 submodule:
  - `openmc-static-lib.patch` — `option(OPENMC_STATIC_LIB)` を追加 (exe 用静的 lib と DLL/so を
    1つのソースツリーから作り分ける)
  - `openmc-dagmc-static.patch` — dagmc-shared ではなく dagmc-static をリンク
  - `openmc-lib-dll-suffix.patch` — `openmc.lib` のロード対象に win32 → `libopenmc.dll` を追加
    (上流は darwin/その他の2分岐しか無い)
  - `openmc-dist-name.patch` — `openmc/__init__.py` の `importlib.metadata.version("openmc")` を
    配布名 `openmc-anywhere` に合わせる (これを怠ると import 自体が PackageNotFoundError で落ちる)
  - `moab-skip-tools.patch` / `dagmc-static-hdf5.patch` — 各ビルドの静的リンク調整
- **共有 lib は out/<triple>/ 経由で wheel に入る**: 上流 CMake の POST_BUILD は
  ソースツリー openmc/lib/ にコピーするが、そこは全 TARGET 共有で同 OS の 2 arch
  (linux の x86_64/aarch64 など) が同名衝突する。build.py がビルド直後に
  out/<triple>/ へ退避し、hatch_build.py の force_include はそちらを拾う。
- **pyproject は自前の thin 定義** (hatchling): 上流 pyproject は setuptools-scm の dynamic
  version が submodule の git メタデータに依存するため使わない。version はここで静的に固定し、
  submodule を進めるときに手で上げる。依存リストは上流から verbatim。
- **ビルド産物の混入対策**: hatchling は submodule 内の .gitignore を適用しない (実測:
  `liblibopenmc.a` も `libopenmc.dll` も素通りで wheel に入った) ので、pyproject の
  `exclude = ["*.a", "*.dll", "*.so"]` でビルド産物を一括で締め出し、現プラットフォームの
  共有 lib 1つだけをビルドフックの `force_include` (exclude より優先) で戻す。
  Windows/Linux がソースツリーを共有するため、反対側のライブラリの残骸を拾わないための構成。

## 実装中に判明した想定外の問題

1. **Windows の `-static` shared リンクは一発で成功**した (事前には未検証のリスク扱い)。
   exe と DLL のビルドディレクトリ分離により、懸念だった `_Unwind_Resume` の二重定義も
   最初から発生しなかった。
2. **Linux の FindHDF5 は静的のみのインストールを見つけられない** ため
   `HDF5_USE_STATIC_LIBRARIES=ON` が必要 (実測: moab の configure で
   `Could NOT find HDF5` )。ただし **同じフラグを Windows に渡すとリンク順が変わって
   逆に壊れる** (実測: それまで通っていた exe リンクが `H5Aopen_name` 未解決で失敗)
   ため、build.py では Linux 限定にしている (`HDF5_STATIC_ARG`)。
3. **リンク順問題**: CMake が組むリンク行は `...libhdf5.a ... libMOAB.a` の順になり、
   単一パスの ld では MOAB の mhdf だけが使う deprecated API (`H5Aopen_name` /
   `H5Fis_hdf5`) が未解決になる (他の H5 シンボルは libopenmc が先に引き込んだ
   オブジェクトで偶然足りる)。`CMAKE_CXX_STANDARD_LIBRARIES` で HDF5 をリンク行末尾に
   再掲して解決。
4. **gcc-toolset の `libgomp.a` は非 PIC** で .so に畳めない (実測: TLS 再配置
   R_X86_64_TPOFF32 でリンク失敗)。共有 lib のみ動的 libgomp に切り替え、
   `auditwheel repair` が `libgomp.so.1` を同梱して manylinux_2_28 に retag する。
   exe は静的 libgomp のまま。
5. **一番の山場**: Linux で `openmc.lib` の init が segfault。原因は .so が静的リンクした
   HDF5 のシンボルを全エクスポートし、同一プロセスの h5py が持つ別ビルドの HDF5 と
   ELF のシンボル介入を起こすこと (h5py を import しないプロセスでは同じ .so が正常動作する
   ことで特定)。`-Wl,--exclude-libs,ALL` で解決。Windows の DLL は介入が構造的に無いため
   影響なし。
6. **hatchling は submodule 内の .gitignore を適用しない** (予想と逆。実測:
   `liblibopenmc.a` も `libopenmc.dll` も素通りで wheel に入った)。pyproject の
   `exclude` + ビルドフックの `force_include` でビルド産物の混入を制御。

## 既知の制約

- `openmc.lib` の DLL (Windows) は静的 libgomp を含むため、プロセス内でのアンロードは
  保証しない。通常の使い方 (import して使い続ける) では問題ない。
- MPI / libMesh / UWUW は無効。共有メモリ並列 (OpenMP) は有効。
- 断面積データ・depletion chain は同梱しない。
- macOS wheel (osxcross + flang クロス) は実験的で、実機 macOS での end-to-end 検証は
  未実施。macOS SDK の Linux 上での利用は Xcode ライセンス上グレー (SDK_URL は
  Dockerfile の ARG で差し替え可能)。
- MOAB は LGPL-3.0 で、これを `openmc` 実行ファイルと `libopenmc` に静的リンクして
  再配布している。LGPL-3.0 §4 (Combined Work) は告知の同梱に加えて「改変版 MOAB への
  再リンク手段」の提供を求めるので、PyPI 公開にあたって別途対処が要る。
  現状 wheel の dist-info に入れている第三者ライセンスは `NJOY2016-LICENSE` のみ
  (`hatch_build.py`)。OpenMC / HDF5 / MOAB / DAGMC の LICENSE も同梱すべき。
