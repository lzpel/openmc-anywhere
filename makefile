# openmc-pypi: OpenMC の PyPI 形式バイナリ wheel を作る。`uv add openmc-pypi` だけで
# 公式 OpenMC のコードが Windows / Linux / macOS でそのまま動く (openmc 実行ファイル +
# libopenmc 共有ライブラリ同梱、DAGMC 込み) ことをゴールにする。ビルド手順・パッチは
# mhd-tbr-stell/sandbox-openmc-source (MinGW ネイティブビルドの実証) からの移植。
#
#   make                 # (デフォルト) このホストの TARGET の wheel をビルドし、パスを stdout に印字
#   make check           # wheel を venv に入れて end-to-end 検証 (check.py の3経路。Windows ホスト用)
#   make cross-<triple>  # docker/Dockerfile_<triple> の toolchain イメージ内で wheel をビルド
#                        #   (x86_64|aarch64)-unknown-linux-gnu / (x86_64|aarch64)-apple-darwin
#                        #   / x86_64-pc-windows-gnu
#   make check-linux     # 素の python:3.12 コンテナで Linux wheel を検証 (可搬性の証明)
#   make clean           # build/ prefix/ out/ dist/ venv-check/ を削除
#
# 中間ディレクトリは TARGET ごとに分離する (build/x86_64-pc-windows-gnu など)。src/ の
# submodule とその中のソースツリーだけは全 TARGET で共有する。libopenmc.{dll,so,dylib} は
# 上流 CMake の POST_BUILD でソースツリー openmc/lib/ に落ちるが、同 OS の 2 arch (linux の
# x86_64/aarch64 など) で同名衝突するため、直後に out/<TARGET>/ へ退避し wheel はそちらを拾う。
#
# 設計原則: ターゲット環境依存の設定 (コンパイラ名・SDK・toolchain) は makefile に書かず
# docker/Dockerfile_<triple> の ENV に閉じる。makefile は環境変数 (CC/CXX/FC/OTOOL/
# CMAKE_TOOLCHAIN_FILE/OPENMP_LIB など) を尊重し、無ければホスト向けデフォルトを使う。

# Git Bash が cmake の引数中の Windows パス (-DCMAKE_INSTALL_PREFIX=C:/... など) を
# MSYS パスへ勝手に変換するのを防ぐ (sandbox-openmc-source と同じ対処。Linux では無害)。
export MSYS_NO_PATHCONV=1

# Visual Studio 入りの Windows では cmake のデフォルトが VS ジェネレータになり、
# CMAKE_C_COMPILER=gcc を無視して MSVC/Debug でビルドしてしまう (実測: install が
# bin/Release/libhdf5.lib を探して落ちる)。単一構成の Unix Makefiles に固定する。
# cmake >=3.15 は環境変数 CMAKE_GENERATOR を読む。?= なので docker/CI 側の指定が勝つ
# (linux/darwin コンテナのデフォルトも Unix Makefiles なので実質 Windows 対策)。
export CMAKE_GENERATOR ?= Unix Makefiles

JOBS ?= 8

# ---- ビルドターゲット triple。ホストから自動判別し、cross-% / CI / docker が TARGET=... で上書きする ----
ifeq ($(OS),Windows_NT)
  TARGET ?= x86_64-pc-windows-gnu
else ifeq ($(shell uname -s),Darwin)
  TARGET ?= $(subst arm64,aarch64,$(shell uname -m))-apple-darwin
else
  TARGET ?= $(shell uname -m)-unknown-linux-gnu
endif

# TARGET から導出 (OSNAME は windows / linux / darwin)
ARCH := $(firstword $(subst -, ,$(TARGET)))
ifneq (,$(findstring windows,$(TARGET)))
  OSNAME := windows
else ifneq (,$(findstring apple,$(TARGET)))
  OSNAME := darwin
else
  OSNAME := linux
endif

# pyproject.toml の version と単一ソース化 (submodule を進めたら pyproject 側を上げる)
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)

SRC    := $(CURDIR)/src
BUILD  := $(CURDIR)/build/$(TARGET)
PREFIX := $(CURDIR)/prefix/$(TARGET)
OUT    := $(CURDIR)/out/$(TARGET)

# GNU Make の組み込みデフォルト (cc / f77 / 組み込み CXX) は掴んではいけない (存在しない
# cc/f77 で configure が落ちる) が、環境変数 (docker イメージの ENV。osxcross の
# o64-clang 等) は尊重したい。?= は組み込みデフォルトを「定義済み」扱いして発火せず、
# = は環境変数を潰す。origin が default のときだけ上書きすることで両立する。
ifeq ($(origin CC),default)
  CC = gcc
endif
ifeq ($(origin CXX),default)
  CXX = g++
endif
ifeq ($(origin FC),default)
  FC = gfortran
endif
# darwin cross では docker ENV が cctools の <triple>-otool を指す
OTOOL ?= otool

# NJOY の CMake は configure 時に Python3 を要求する。ホストの python は
# Microsoft Store のスタブなので uv 管理のインタプリタを名指しする
# (manylinux コンテナにも uv が入っているので全 OS で同じ書き方が通る)。
# subst: Windows の uv はバックスラッシュ区切りで返し、shell 経由で \ が食われて
# "C:UserssmithAppData..." になる (実測) ためスラッシュに正規化する。
PYTHON3 = $(subst \,/,$(shell uv python find))

# CMake の FindOpenMP は OpenMP ランタイムを「インポートライブラリの絶対パス」
# (.../libgomp.dll.a) として渡してくる。絶対パス指定は -static では覆せないので、
# そのままだと libgomp-1.dll (Linux では libgomp.so.1) への動的リンクが残り
# スタンドアローン性が壊れる。静的版を名指しして上書きする。
# ライブラリ名は GCC 系が gomp、clang 系 (darwin cross) が omp — docker ENV が
# OPENMP_LIB_NAME=omp / OPENMP_LIB=/opt/omp/lib/libomp.a を注入する (?= は環境を尊重)。
OPENMP_LIB_NAME ?= gomp
OPENMP_LIB ?= $(shell $(CXX) -print-file-name=lib$(OPENMP_LIB_NAME).a)

# 共有ライブラリと実行ファイルの拡張子。hatch_build.py には SOEXT をそのまま渡す。
ifeq ($(OSNAME),windows)
  SOEXT   = dll
  EXE_EXT = .exe
else ifeq ($(OSNAME),darwin)
  SOEXT   = dylib
  EXE_EXT =
else
  SOEXT   = so
  EXE_EXT =
endif

EXE      = $(OUT)/openmc$(EXE_EXT)
NJOY_EXE = $(OUT)/njoy$(EXE_EXT)
# 上流 CMake の POST_BUILD がソースツリーに落とす場所 (同 OS の 2 arch で同名衝突する)
SHLIB     = $(SRC)/openmc/openmc/lib/libopenmc.$(SOEXT)
# per-target の退避先。wheel (hatch_build.py の force_include) はこちらを拾う
SHLIB_OUT = $(OUT)/libopenmc.$(SOEXT)

# OS ごとのリンクフラグと wheel プラットフォームタグ。
#   windows: -static 一発で libstdc++/libgcc/libwinpthread まで全部畳める (exe で実測済み)。
#   linux:   glibc は manylinux の前提なので動的のまま、gcc ランタイムだけ静的にする。
#            wheel タグは manylinux_2_28_<arch> (ビルドを quay.io/pypa/manylinux_2_28 で行い、
#            glibc 以外への動的依存を ldd 検査で排除することが根拠)。
#   darwin:  osxcross (clang) の docker クロス。システム libc++/libSystem は全 macOS に
#            あるので RUNTIME_STATIC は不要。deployment target 11.0 は docker ENV の
#            MACOSX_DEPLOYMENT_TARGET と PLAT のタグで対にして管理する。実験的。
ifeq ($(OSNAME),windows)
  RUNTIME_STATIC = -static
  PLAT           = win_amd64
  LINK_TAIL      =
  # -static 一発で libgfortran/quadmath/winpthread まで畳める (openmc.exe と同じ)
  NJOY_STATIC    = -static
else ifeq ($(OSNAME),darwin)
  RUNTIME_STATIC =
  PLAT           = macosx_11_0_$(subst aarch64,arm64,$(ARCH))
  # ld64 は単一パスの ld ではないのでリンク順問題 (linux の LINK_TAIL) は構造的に起きない
  LINK_TAIL      =
  # FindHDF5 が既定で共有ライブラリを探すのは Linux と同じ → 静的のみインストールには必須
  HDF5_STATIC_ARG = -DHDF5_USE_STATIC_LIBRARIES=ON
  # flang の Fortran ランタイムの畳み方は docker ENV (NJOY_STATIC) 側で調整する
  NJOY_STATIC   ?=
else
  RUNTIME_STATIC = -static-libgcc -static-libstdc++
  PLAT           = manylinux_2_28_$(ARCH)
  # CMake が組むリンク行は ...libhdf5.a ... libMOAB.a の順になり、単一パスの ld では
  # MOAB の mhdf が使う deprecated API (H5Aopen_name / H5Fis_hdf5) だけが未解決になる
  # (他の H5 シンボルは libopenmc が先に引き込んだオブジェクトで偶然足りる。実測)。
  # CMAKE_CXX_STANDARD_LIBRARIES は全 exe/共有 lib のリンク行末尾に付くので、HDF5 を
  # 再掲して閉じる。Linux の既定値は空なので上書きしても何も失わない
  # (Windows は -lkernel32 等の既定があるため触らない。MinGW では元の順で通っている)。
  LINK_TAIL      = -DCMAKE_CXX_STANDARD_LIBRARIES="$(PREFIX)/lib/libhdf5_hl.a $(PREFIX)/lib/libhdf5.a"
  # wheel はまず素の linux_<arch> タグで作り、auditwheel repair が libgomp.so.1 を
  # 同梱して manylinux_2_28 に retag する (下記 OPENMP_ARGS_LIB 参照)。
  PLAT_BUILD     = linux_$(ARCH)
  # Linux の FindHDF5 は既定で .so を探すため、静的のみのインストールだと
  # HDF5_LIBRARIES が見つからず configure が落ちる (実測、moab で発生)。
  # Windows に渡してはいけない: MinGW では .a が import-lib の拡張子でもあるため
  # 指定なしで通っており、指定するとリンク順が変わって MOAB の deprecated API
  # (H5Aopen_name) が未解決になる (実測)。
  HDF5_STATIC_ARG = -DHDF5_USE_STATIC_LIBRARIES=ON
  # gcc-toolset-14 に libgfortran.a / libquadmath.a がある (実測 probe)。
  # -static-libquadmath は GCC>=13。glibc は動的のまま = manylinux の前提どおり
  NJOY_STATIC    = -static-libgfortran -static-libquadmath -static-libgcc
endif
PLAT_BUILD ?= $(PLAT)

# 検証用の断面積とデータ。wheel には焼き込まない (利用者が OPENMC_CROSS_SECTIONS で渡す)。
XSDIR ?= C:/Users/smith/mhd-tbr-stell/sandbox-openmc/data
XS    ?= $(XSDIR)/lib/cross_sections.xml
ENDF  ?= $(XSDIR)/endf/Li6.endf
H5M   := $(SRC)/openmc/tests/regression_tests/dagmc/legacy/dagmc.h5m

# -DCMAKE_POSITION_INDEPENDENT_CODE=ON: hdf5/moab/dagmc の静的 archive は Linux で
# libopenmc.so に畳まれるので PIC が必須。Windows (PE) では無害な no-op。
CMAKE_COMMON = -DCMAKE_BUILD_TYPE=Release \
               -DCMAKE_C_COMPILER=$(CC) -DCMAKE_CXX_COMPILER=$(CXX) \
               -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
               -DCMAKE_INSTALL_PREFIX=$(PREFIX)

# 全ビルド出力を 1>&2 に流すのは、デフォルトターゲットが stdout に wheel のパスだけを
# 出す必要があるため (sandbox-openfoam/epotFoam 以来のイディオム)。
E = 1>&2

.PHONY: default src hdf5 moab dagmc njoy openmc-exe openmc-lib wheel check check-linux release clean

# ---- デフォルト: wheel をビルドし、そのパスだけを stdout に出す ----
default: wheel
	@ls dist/openmc_pypi-*-$(PLAT).whl

# ================= 段0: ソース =================
# 上流は全部 submodule で取得する。openmc は full clone (タグが入り CMake の
# GetVersionFromGit がそのまま動く。shallow だと openmc --version が 0.0.0 になる)。
# moab は tarball 不可 — 配布 tarball は autotools の `make dist` 産物で、CMake 用の
# config/{logging,dist,distcheck}.cmake が EXTRA_DIST から漏れており configure が落ちる —
# ため git (submodule)。
# パッチは src/*.patch を全部当てる。当て先はファイル名の最初の '-' より前のトークン
# (openmc-static-lib.patch → src/openmc)。適用済みなら黙って飛ばす (.PHONY なので毎回
# このレシピに入るため、-R --dry-run が通る = すでに当たっている、という判定にする)。
# while が pipe の最終段なので中の exit 1 がそのまま make に伝播する。
src:
	@git submodule update --init --recursive $(E)
	@find src -maxdepth 1 -name '*.patch' | sort | while read p; do \
	  b=$$(basename $$p .patch); d=$(SRC)/$${b%%-*}; \
	  if patch -p1 -d $$d -R --dry-run -s -f < "$$p" >/dev/null 2>&1; then \
	    echo "$$b: already applied" >&2; \
	  else \
	    patch -p1 -d $$d < "$$p" $(E) || exit 1; \
	    echo "$$b: applied" >&2; \
	  fi; \
	done

# ================= 段1: HDF5 =================
# 静的 (BUILD_SHARED_LIBS=OFF) にして Windows の DLL シンボル export 問題を丸ごと回避する。
# OpenMC は C API と HL のみ使うので C++/Fortran/tools は全部切る。zlib は HDF5 2.x の既定通り OFF。
hdf5: src
	@command -v cmake >/dev/null \
	  || { echo "cmake not found in PATH; install it and retry" >&2; exit 1; }
	cmake -S $(SRC)/hdf5 -B $(BUILD)/hdf5 $(CMAKE_COMMON) \
	  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
	  -DBUILD_TESTING=OFF -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_TOOLS=OFF \
	  -DHDF5_BUILD_HL_LIB=ON -DHDF5_BUILD_CPP_LIB=OFF -DHDF5_BUILD_FORTRAN=OFF \
	  -DHDF5_ENABLE_THREADSAFE=OFF -DHDF5_ENABLE_SZIP_SUPPORT=OFF \
	  -DHDF5_ENABLE_ZLIB_SUPPORT=OFF $(E)
	cmake --build $(BUILD)/hdf5 -j $(JOBS) $(E)
	cmake --install $(BUILD)/hdf5 $(E)

# ================= 段1.5: MOAB =================
# .h5m は MOAB のファイル形式そのもので、DAGMC は MOAB の上の薄い層。静的
# (BUILD_SHARED_LIBS=OFF) にするのが肝: 共有だと MSVC 構文のフラグ (/DMOAB_DLL) が
# GCC に渡り落ちる。既定 ON で落ちるもの (BLASLAPACK/FORTRAN/TESTING) は明示的に切る。
moab: src
	cmake -S $(SRC)/moab -B $(BUILD)/moab $(CMAKE_COMMON) \
	  -DBUILD_SHARED_LIBS=OFF \
	  -DENABLE_HDF5=ON -DHDF5_ROOT=$(PREFIX) $(HDF5_STATIC_ARG) \
	  -DENABLE_BLASLAPACK=OFF -DENABLE_FORTRAN=OFF -DENABLE_TESTING=OFF \
	  -DENABLE_PYMOAB=OFF -DENABLE_NETCDF=OFF -DENABLE_MPI=OFF \
	  -DENABLE_METIS=OFF -DENABLE_ZOLTAN=OFF -DENABLE_PARMETIS=OFF \
	  -DENABLE_TEMPESTREMAP=OFF -DENABLE_CGNS=OFF -DENABLE_CPM=OFF $(E)
	cmake --build $(BUILD)/moab -j $(JOBS) $(E)
	cmake --install $(BUILD)/moab $(E)

# ================= 段1.6: DAGMC =================
# タグ付きリリースを使う。UWUW と TALLY は既定 ON だが OpenMC は使わない (UWUW は PyNE を
# 引き込むので特に切る)。DAGMCConfig.cmake は install prefix を焼き込むので最終位置に直接入れる。
dagmc: moab
	cmake -S $(SRC)/dagmc -B $(BUILD)/dagmc $(CMAKE_COMMON) \
	  -DMOAB_DIR=$(PREFIX) -DHDF5_ROOT=$(PREFIX) $(HDF5_STATIC_ARG) \
	  -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF \
	  -DBUILD_UWUW=OFF -DBUILD_TALLY=OFF \
	  -DBUILD_BUILD_OBB=OFF -DBUILD_MAKE_WATERTIGHT=OFF -DBUILD_OVERLAP_CHECK=OFF \
	  -DBUILD_TESTS=OFF -DBUILD_CI_TESTS=OFF \
	  -DBUILD_EXE=OFF -DBUILD_STATIC_EXE=OFF -DBUILD_RPATH=OFF \
	  -DDOUBLE_DOWN=OFF -DPULL_INSTALL_MOAB=OFF $(E)
	cmake --build $(BUILD)/dagmc -j $(JOBS) $(E)
	cmake --install $(BUILD)/dagmc $(E)

# ================= 段1.7: NJOY2016 =================
# openmc.data.IncidentNeutron.from_njoy() が PATH 上の literal 'njoy' を Popen する
# (openmc/data/njoy.py:358) ので、openmc.exe と同じ .data/scripts 同梱で成立する。
# tests/ は ctest 登録のみでビルド産物なし → njoy_executable ターゲットだけビルドすれば
# テスト無効化スイッチは不要。install ターゲットが無いので build dir から自前でコピー。
# CMAKE_COMMON は使わない (Fortran 専用で C/C++・install prefix・PIC のどれも不要。
# クロスは環境変数 CMAKE_TOOLCHAIN_FILE が全 cmake 呼び出しに効くのでここも成立する)。
# Windows ビルドは前例なし (上流 CI は ubuntu のみ、conda-forge は skip: win)、darwin は
# flang クロス (docker ENV の FC) — 壊れたら src/njoy-*.patch に最小パッチを足す。
njoy: src
	cmake -S $(SRC)/njoy -B $(BUILD)/njoy -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_Fortran_COMPILER=$(FC) -DPython3_EXECUTABLE=$(PYTHON3) \
	  -DCMAKE_EXE_LINKER_FLAGS="$(NJOY_STATIC)" $(E)
	cmake --build $(BUILD)/njoy -j $(JOBS) --target njoy_executable $(E)
	@mkdir -p $(OUT)
	cp $(BUILD)/njoy/njoy$(EXE_EXT) $(NJOY_EXE) $(E)

# ================= 段2a: openmc 実行ファイル (libopenmc 静的) =================
# OPENMC_STATIC_LIB=ON (src/openmc-static-lib.patch) で libopenmc を静的にし、
# exe をランタイムごと自己完結にする。DLL と exe を同じビルドでリンクすると MinGW の
# 全シンボル自動エクスポートで _Unwind_Resume が exe 側静的 libgcc_eh.a と multiple
# definition になる (sandbox-openmc-source で実測) ので、exe と共有ライブラリは
# ビルドディレクトリごと分ける。コンパイル2倍は構造的安全のコスト。
OPENMC_CMAKE = $(CMAKE_COMMON) \
	  -DHDF5_ROOT=$(PREFIX) -DHDF5_PREFER_PARALLEL=FALSE $(HDF5_STATIC_ARG) \
	  -DOPENMC_USE_OPENMP=ON -DOPENMC_BUILD_TESTS=OFF \
	  -DOPENMC_FORCE_VENDORED_LIBS=ON \
	  -DOPENMC_USE_MPI=OFF -DOPENMC_USE_LIBMESH=OFF \
	  -DOPENMC_USE_DAGMC=ON -DOPENMC_USE_UWUW=OFF -DCMAKE_PREFIX_PATH=$(PREFIX) \
	  $(LINK_TAIL)

# 静的 OpenMP の名指し (根拠は OPENMP_LIB のコメント)。exe は全 OS で使える。共有 lib は
# OS ごと: gcc-toolset (linux) の libgomp.a は非 PIC (TLS 再配置 R_X86_64_TPOFF32) で
# .so に畳めない (実測) ため、Linux の共有 lib は動的 libgomp のままにして
# auditwheel repair に同梱させる。darwin のオブジェクトは常に PIC なので畳める見込み。
OPENMP_STATIC = -DOpenMP_CXX_LIB_NAMES=$(OPENMP_LIB_NAME) -DOpenMP_C_LIB_NAMES=$(OPENMP_LIB_NAME) \
	  -DOpenMP_$(OPENMP_LIB_NAME)_LIBRARY="$(OPENMP_LIB)"
# FindOpenMP は OpenMP_<lang>_FLAGS と _LIB_NAMES の両方が事前設定のときだけ try_compile
# 検出をスキップする。上は LIB_NAMES しか渡さないので検出が走り、osxcross の
# aarch64-apple-darwin では検出が失敗して configure ごと落ちる (CI run 29983656072 で実測。
# x86_64 は偶然通る)。darwin の docker ENV が OPENMP_FLAGS=-fopenmp を注入して両方を
# 揃え、検出を丸ごとバイパスする。未定義の環境 (linux / windows) は従来通り検出に任せる。
ifdef OPENMP_FLAGS
  OPENMP_STATIC += -DOpenMP_C_FLAGS="$(OPENMP_FLAGS)" -DOpenMP_CXX_FLAGS="$(OPENMP_FLAGS)"
endif
ifeq ($(OSNAME),windows)
  OPENMP_ARGS_LIB = $(OPENMP_STATIC)
  SHLIB_LDFLAGS   = $(RUNTIME_STATIC)
else ifeq ($(OSNAME),darwin)
  # Mach-O は two-level namespace なので、同一プロセスの h5py が持つ別ビルド HDF5 との
  # シンボル介入 (linux の --exclude-libs,ALL の理由) は構造的に起きない (Windows と同じ理屈)。
  OPENMP_ARGS_LIB = $(OPENMP_STATIC)
  SHLIB_LDFLAGS   = $(RUNTIME_STATIC)
else
  OPENMP_ARGS_LIB =
  # --exclude-libs,ALL: 静的 archive 由来のシンボル (H5* / MOAB / pugixml / fmt) を
  # .so からエクスポートしない。しないと同一プロセスの h5py が持つ別ビルドの HDF5 と
  # ELF のシンボル介入 (interposition) が起き、openmc_init が segfault する
  # (実測: h5py を import しないプロセスでは同じ .so が正常動作)。Windows の DLL は
  # そもそも介入が構造的に無いので不要。
  SHLIB_LDFLAGS   = $(RUNTIME_STATIC) -Wl,--exclude-libs,ALL
endif

openmc-exe: hdf5 dagmc
	cmake -S $(SRC)/openmc -B $(BUILD)/openmc-exe $(OPENMC_CMAKE) $(OPENMP_STATIC) \
	  -DOPENMC_STATIC_LIB=ON \
	  -DCMAKE_EXE_LINKER_FLAGS="$(RUNTIME_STATIC)" $(E)
	cmake --build $(BUILD)/openmc-exe -j $(JOBS) $(E)
	cmake --install $(BUILD)/openmc-exe $(E)
	@mkdir -p $(OUT)
	cp $(PREFIX)/bin/openmc* $(OUT)/ $(E)

# ================= 段2b: libopenmc 共有ライブラリ (openmc.lib 用) =================
# SHARED でも RUNTIME_STATIC でランタイムを畳み、CDLL が絶対パスだけでロードできる
# 自己完結な DLL/so/dylib にする。ビルドは libopenmc ターゲットのみ (exe をリンクしないので
# 上記の multiple definition が構造的に起きない)。出来上がりは上流 CMakeLists の POST_BUILD
# がソースツリー openmc/lib/ にコピーするが、そこは全 TARGET 共有で同 OS の 2 arch が
# 同名衝突するため、直後に per-target の out/ へ退避する。wheel はそちらを拾う。
openmc-lib: hdf5 dagmc
	cmake -S $(SRC)/openmc -B $(BUILD)/openmc-lib $(OPENMC_CMAKE) $(OPENMP_ARGS_LIB) \
	  -DCMAKE_SHARED_LINKER_FLAGS="$(SHLIB_LDFLAGS)" $(E)
	cmake --build $(BUILD)/openmc-lib -j $(JOBS) --target libopenmc $(E)
	@test -f $(SHLIB) || { echo "POST_BUILD copy did not produce $(SHLIB)" >&2; exit 1; }
	@mkdir -p $(OUT)
	cp $(SHLIB) $(SHLIB_OUT) $(E)

# ================= 段3: wheel =================
# タグは py3-none-$(PLAT) (hatch_build.py が OPENMC_PYPI_PLAT から組む)。python パッケージは
# pure Python なので CPython バージョン別の wheel は要らない。
# uv は manylinux イメージにも同梱されているので全 OS で同じコマンドが使える。
# WITH_NJOY=0 で njoy 無し wheel になる (darwin の flang クロスが通らない場合の
# 逃げ道。docker ENV で立てればイメージ内に閉じる)。
WITH_NJOY ?= 1
WHEEL_CMD = uv build --wheel --out-dir dist

wheel: openmc-exe openmc-lib $(if $(filter 1,$(WITH_NJOY)),njoy)
	OPENMC_PYPI_PLAT=$(PLAT_BUILD) OPENMC_PYPI_OUT=out/$(TARGET) \
	  OPENMC_PYPI_SOEXT=$(SOEXT) \
	  $(if $(filter 1,$(WITH_NJOY)),OPENMC_PYPI_NJOY=$(NJOY_EXE)) \
	  $(WHEEL_CMD) $(E)
ifeq ($(OSNAME),linux)
# 素の linux_<arch> タグで作った wheel を auditwheel repair が libgomp.so.1 を
# 同梱 (openmc_pypi.libs/、RPATH 書き換え) して manylinux_2_28 に retag する。
# ldd 断言: exe は glibc のみ (libgomp は静的)。.so は glibc + libgomp のみ
# (libgomp は repair が畳む) で、それ以外の動的依存が紛れたら失敗させる。
	@echo "== ldd ==" >&2
	@ldd $(SHLIB_OUT) >&2
	@! ldd $(SHLIB_OUT) | grep -viE "linux-vdso|libc\.|libm\.|libpthread|libdl|librt|ld-linux|libgomp" | grep -q "=>" \
	  || { echo "unexpected shared dependency in libopenmc.so" >&2; exit 1; }
	@! ldd $(EXE) | grep -viE "linux-vdso|libc\.|libm\.|libpthread|libdl|librt|ld-linux" | grep -q "=>" \
	  || { echo "unexpected shared dependency in openmc" >&2; exit 1; }
	@# libmvec は glibc 2.22+ 同梱のベクトル数学ライブラリ (gfortran の自動ベクトル化が参照)。
	@# manylinux_2_28 の glibc 2.28 前提に含まれるので許可する。
	@if [ "$(WITH_NJOY)" = 1 ]; then \
	  ldd $(NJOY_EXE) | grep -viE "linux-vdso|libc\.|libm\.|libmvec|libpthread|libdl|librt|ld-linux" | grep -q "=>" \
	    && { echo "unexpected shared dependency in njoy" >&2; exit 1; } || true; \
	fi
	auditwheel repair --plat $(PLAT) -w dist dist/openmc_pypi-*-$(PLAT_BUILD).whl $(E)
	rm dist/openmc_pypi-*-$(PLAT_BUILD).whl
endif
ifeq ($(OSNAME),darwin)
# otool -L 断言 (クロス環境でも cctools の <triple>-otool で検査できる)。許可するのは
# 自分自身の install name と /usr/lib のシステムライブラリ (libSystem / libc++。全 macOS に
# 存在) のみ。それ以外の依存 (/opt/... や @rpath) が残ったら自己完結が壊れているので失敗させる。
	@echo "== otool -L ==" >&2
	@$(OTOOL) -L $(SHLIB_OUT) >&2
	@! $(OTOOL) -L $(SHLIB_OUT) | tail -n +2 | grep -viE "libopenmc|/usr/lib/" | grep -q "compatibility" \
	  || { echo "unexpected dylib dependency in libopenmc.dylib" >&2; exit 1; }
	@! $(OTOOL) -L $(EXE) | tail -n +2 | grep -viE "/usr/lib/" | grep -q "compatibility" \
	  || { echo "unexpected dylib dependency in openmc" >&2; exit 1; }
	@if [ "$(WITH_NJOY)" = 1 ]; then \
	  $(OTOOL) -L $(NJOY_EXE) | tail -n +2 | grep -viE "/usr/lib/" | grep -q "compatibility" \
	    && { echo "unexpected dylib dependency in njoy" >&2; exit 1; } || true; \
	fi
endif

# ================= 検証 =================
# wheel を venv に入れ、check.py の3経路 (subprocess / openmc.lib / DAGMC) を通す。
# Windows ホスト用 (objdump / cygpath / Scripts 前提)。
# PATH に venv の Scripts を前置するのが肝: python.exe を直接叩くだけでは Scripts が
# PATH に乗らず、executor.py の literal 'openmc' 解決 (利用者が activate した状態の
# 再現) が失敗する。
# objdump の断言2つ: DLL の import が Windows 同梱のシステム DLL のみ (自己完結の証明。
# SHLWAPI は HDF5 が Win32 API 経由で使う、全 Windows に存在する DLL)、
# かつ openmc_init をエクスポート (ctypes が読める形の証明)。
check: wheel
	@echo "== DLL self-containment ==" >&2
	@objdump -p $(SHLIB_OUT) | grep "DLL Name" >&2 || true
	@! objdump -p $(SHLIB_OUT) | grep "DLL Name" | grep -viE "KERNEL32|SHELL32|SHLWAPI|api-ms-win-crt|ntdll|msvcrt" \
	  || { echo "unexpected DLL dependency" >&2; exit 1; }
	@objdump -p $(SHLIB_OUT) | grep -q openmc_init || { echo "openmc_init not exported" >&2; exit 1; }
	@! objdump -p $(NJOY_EXE) | grep "DLL Name" | grep -viE "KERNEL32|SHELL32|SHLWAPI|api-ms-win-crt|ntdll|msvcrt" \
	  || { echo "unexpected DLL dependency in njoy" >&2; exit 1; }
	uv venv venv-check --python 3.12 --allow-existing $(E)
	uv pip install --python venv-check --reinstall dist/openmc_pypi-*-$(PLAT).whl $(E)
	@rm -rf $(BUILD)/check-run && mkdir -p $(BUILD)/check-run
	cd $(BUILD)/check-run && \
	  PATH="$$(cygpath -u $(CURDIR)/venv-check/Scripts):$$PATH" \
	  OPENMC_CROSS_SECTIONS="$(XS)" \
	  $(CURDIR)/venv-check/Scripts/python.exe $(CURDIR)/check.py $(H5M) --endf "$(ENDF)"

# ================= クロスビルド (Docker) =================
# docker/Dockerfile_<triple> の toolchain イメージ (project 非依存、ソースは実行時
# bind-mount) を組み、repo をマウントして同じ makefile を TARGET=<triple> で回す
# (github.com/lzpel/cadrum の方式)。環境依存の設定 (コンパイラ・SDK・toolchain) は
# 全部イメージの ENV に閉じており、makefile 側に分岐は増えない。
# safe.directory: マウントした repo の所有者が container の root と食い違うため。
cross-%:
	docker build -f docker/Dockerfile_$* -t cross-$* . $(E)
	docker run --rm -v $(CURDIR):/io -w /io cross-$* \
	  bash -c "git config --global --add safe.directory '*' && make wheel TARGET=$* JOBS=$(JOBS)" $(E)
	@ls dist/openmc_pypi-*.whl

# 検証はビルドイメージではなく素の python:3.12 で行う (可搬性の証明)。データは読み取りで
# 足りるので :ro。check.py の生成物はコンテナ内 /tmp に落ちて廃棄される。
# python:3.12 はホストの arch で解決されるので、arm ホストなら aarch64 wheel の検証になる
# (glob の manylinux* は両 arch にマッチする)。
check-linux:
	docker run --rm -v $(CURDIR):/io:ro -v $(XSDIR):/data:ro \
	  -e OPENMC_CROSS_SECTIONS=/data/lib/cross_sections.xml python:3.12 \
	  bash -c "pip install -q /io/dist/openmc_pypi-*-manylinux*.whl \
	    && mkdir /tmp/run && cd /tmp/run \
	    && python /io/check.py /io/src/openmc/tests/regression_tests/dagmc/legacy/dagmc.h5m \
	         --endf /data/endf/Li6.endf"

# ================= 公開 =================
# wheel は git に入れず Release asset として配る。CI (.github/workflows/prebuilt.yml) が
# prebuilt ブランチへの push で全 TARGET をビルドして Release を自動作成するのが正規経路。
# この手動 release は逃げ道として残す。publish イベント (手動 release 時) または CI の
# workflow_dispatch を Pages workflow (.github/workflows/pages.yml) が拾い、simple index を
# 再生成する。バージョン明示 glob で古い版の wheel が紛れ込むのを防ぐ。
# タグ既存なら gh が落ちる (= 意図通り)。
release:
	gh release create v$(VERSION) --title v$(VERSION) \
	  --notes "openmc + libopenmc + njoy bundled wheels" \
	  dist/openmc_pypi-$(VERSION)-py3-none-*.whl $(E)

clean:
	rm -rf $(CURDIR)/build $(CURDIR)/prefix $(CURDIR)/out dist venv-check
