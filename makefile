export MSYS_NO_PATHCONV=1

# ---- ビルドターゲット triple。ホストから自動判別し、cross-% / CI / docker が上書きする ----
TARGET ?= $(shell uname -m | sed 's/arm64/aarch64/')-$(shell uname -s | sed -e 's/Darwin/apple-darwin/' -e 's/Linux/unknown-linux-gnu/' -e 's/^\(MINGW\|MSYS\|CYGWIN\).*/pc-windows-gnu/')

default: wheel ## default: wheel 段の依存 (hdf5→source, dagmc→moab, wheel→exe+lib+njoy ...) は下の A〜B
## A
# 環境の事実 (コンパイラ・SDK・toolchain) は docker/Dockerfile_<triple> の ENV に閉じる。
# ここは TARGET から一意に決まる方針だけを持ち、全て同名の環境変数で上書きできる。
OS := $(if $(findstring windows,$(TARGET)),windows,$(if $(findstring apple,$(TARGET)),darwin,linux))
ARCH := $(firstword $(subst -, ,$(TARGET)))
JOBS ?= 8

# GNU Make の組み込み既定 (cc / f77) は使わない。docker ENV が設定していればそちらが勝つ。
CC := $(if $(filter default,$(origin CC)),gcc,$(CC))
CXX := $(if $(filter default,$(origin CXX)),g++,$(CXX))
FC := $(if $(filter default,$(origin FC)),gfortran,$(FC))
OTOOL ?= otool

BUILD := build/$(TARGET)
OUT := out/$(TARGET)
# ここだけ絶対パス。CMAKE_CXX_STANDARD_LIBRARIES (LINK_TAIL) に書いた .a は cmake が
# 相対のままリンク行へ通し、リンクは cwd=ビルドディレクトリで走るので解決できない (実測)。
PREFIX := $(abspath prefix/$(TARGET))

SOEXT_windows := dll
SOEXT_darwin := dylib
SOEXT_linux := so
SOEXT := $(SOEXT_$(OS))
EXE_windows := .exe
EXE := $(EXE_$(OS))

# wheel タグ。linux はまず素の linux_<arch> で作り auditwheel repair が manylinux に retag する
PLAT_windows := win_amd64
PLAT_darwin := macosx_11_0_$(subst aarch64,arm64,$(ARCH))
PLAT_linux := manylinux_2_28_$(ARCH)
PLAT := $(PLAT_$(OS))
PLAT_BUILD_windows := $(PLAT_windows)
PLAT_BUILD_darwin := $(PLAT_darwin)
PLAT_BUILD_linux := linux_$(ARCH)
PLAT_BUILD := $(PLAT_BUILD_$(OS))

# windows は -static 一発で libstdc++/libgcc/libwinpthread まで畳める。darwin はシステム
# libc++/libSystem が全 macOS にあるので静的化不要。linux は glibc を動的のまま残す (manylinux の前提)。
RUNTIME_STATIC_windows := -static
RUNTIME_STATIC_linux := -static-libgcc -static-libstdc++
RUNTIME_STATIC ?= $(RUNTIME_STATIC_$(OS))

# FindHDF5 は既定で共有ライブラリを探すので静的のみの install には明示が要る。MinGW では
# .a が import-lib の拡張子でもあるため渡してはいけない: 指定するとリンク順が変わって
# MOAB の deprecated API (H5Aopen_name) が未解決になる (実測)。
HDF5_STATIC_ARG_darwin := -DHDF5_USE_STATIC_LIBRARIES=ON
HDF5_STATIC_ARG_linux := -DHDF5_USE_STATIC_LIBRARIES=ON
HDF5_STATIC_ARG ?= $(HDF5_STATIC_ARG_$(OS))

# CMake が組むリンク行は libhdf5.a ... libMOAB.a の順になり、単一パスの ld では MOAB の mhdf が
# 使う deprecated API (H5Aopen_name / H5Fis_hdf5) だけが未解決になる (実測)。
# CMAKE_CXX_STANDARD_LIBRARIES は全リンク行の末尾に付くので HDF5 を再掲して閉じる。
# ld64 (darwin) は単一パスの ld ではないのでこの問題は構造的に起きない。
LINK_TAIL_linux := "-DCMAKE_CXX_STANDARD_LIBRARIES=$(PREFIX)/lib/libhdf5_hl.a $(PREFIX)/lib/libhdf5.a"
LINK_TAIL ?= $(LINK_TAIL_$(OS))

# gcc-toolset-14 に libgfortran.a / libquadmath.a がある (実測)。-static-libquadmath は GCC>=13。
# darwin の flang の畳み方は docker ENV の NJOY_STATIC 側で調整する。
NJOY_STATIC_windows := -static
NJOY_STATIC_linux := -static-libgfortran -static-libquadmath -static-libgcc
NJOY_STATIC ?= $(NJOY_STATIC_$(OS))

# FindOpenMP は OpenMP ランタイムを import ライブラリの絶対パスで渡してくる。絶対パス指定は
# -static では覆せず libgomp-1.dll への動的リンクが残るので、静的版を名指しして上書きする。
# 名前は GCC 系が gomp、clang 系 (darwin cross) が omp — docker ENV が OPENMP_LIB* を注入する。
OPENMP_LIB_NAME ?= gomp
OPENMP_LIB ?= $(shell $(CXX) -print-file-name=lib$(OPENMP_LIB_NAME).a)
# OPENMP_FLAGS: FindOpenMP は FLAGS と LIB_NAMES の両方が事前設定のときだけ try_compile 検出を
# スキップする。osxcross の aarch64 は検出が失敗して configure ごと落ちる (CI run 29983656072)
# ため darwin の docker ENV が -fopenmp を注入して検出を丸ごとバイパスする。
OPENMP_STATIC = -DOpenMP_CXX_LIB_NAMES=$(OPENMP_LIB_NAME) -DOpenMP_C_LIB_NAMES=$(OPENMP_LIB_NAME) -DOpenMP_$(OPENMP_LIB_NAME)_LIBRARY=$(OPENMP_LIB) $(if $(OPENMP_FLAGS),-DOpenMP_C_FLAGS=$(OPENMP_FLAGS) -DOpenMP_CXX_FLAGS=$(OPENMP_FLAGS))

# -DCMAKE_POSITION_INDEPENDENT_CODE=ON: hdf5/moab/dagmc の静的 archive は linux で
# libopenmc.so に畳まれるので PIC が必須。Windows (PE) では無害な no-op。
CMAKE_COMMON := -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=$(CC) -DCMAKE_CXX_COMPILER=$(CXX) -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=$(PREFIX)
OPENMC_CMAKE := $(CMAKE_COMMON) -DHDF5_ROOT=$(PREFIX) -DHDF5_PREFER_PARALLEL=FALSE -DOPENMC_USE_OPENMP=ON -DOPENMC_BUILD_TESTS=OFF -DOPENMC_FORCE_VENDORED_LIBS=ON -DOPENMC_USE_MPI=OFF -DOPENMC_USE_LIBMESH=OFF -DOPENMC_USE_DAGMC=ON -DOPENMC_USE_UWUW=OFF -DCMAKE_PREFIX_PATH=$(PREFIX) $(HDF5_STATIC_ARG) $(LINK_TAIL)

# 上流 CMake の POST_BUILD がソースツリーに落とす場所は全 TARGET 共有で同 OS の 2 arch が
# 同名衝突するため、per-target の out/ へ退避する。wheel (hatch_build.py) はそちらを拾う。
SHLIB := src/openmc/openmc/lib/libopenmc.$(SOEXT)
SHLIB_OUT := $(OUT)/libopenmc.$(SOEXT)
OPENMC_EXE := $(OUT)/openmc$(EXE)
NJOY_EXE := $(OUT)/njoy$(EXE)
WHEEL_GLOB := dist/openmc_anywhere-*-py3-none-$(PLAT).whl
VENV_BIN := venv-check/$(if $(filter windows,$(OS)),Scripts,bin)

# ---- 自己完結の断言。許可リストに載らない動的依存が1つでも残っていたら失敗させる ----
DEPS_linux = ldd $1 | grep '=>' | sed 's/=>.*//' | tr -d ' \t'
DEPS_darwin = $(OTOOL) -L $1 | tail -n +2 | sed -n 's/^[[:space:]]*\([^[:space:]]*\).*compatibility.*/\1/p'
DEPS_windows = objdump -p $1 | sed -n 's/.*DLL Name: *//p'
# glibc は manylinux_2_28 の前提なので動的のまま。libgomp は .so だけ動的に残り auditwheel が同梱する。
# libmvec は glibc 2.22+ 同梱のベクトル数学ライブラリ (gfortran の自動ベクトル化が参照)。
ALLOW_GLIBC := linux-vdso|libc\.|libm\.|libpthread|libdl|librt|ld-linux
ALLOW_linux_lib := $(ALLOW_GLIBC)|libgomp
ALLOW_linux_exe := $(ALLOW_GLIBC)
ALLOW_linux_njoy := $(ALLOW_GLIBC)|libmvec
# 許すのは自分自身の install name と /usr/lib のシステムライブラリのみ。@rpath が残っていたら壊れている。
ALLOW_darwin_lib := libopenmc|/usr/lib/
ALLOW_darwin_exe := /usr/lib/
ALLOW_darwin_njoy := /usr/lib/
# SHLWAPI は HDF5 が Win32 API 経由で使う、全 Windows に存在する DLL
ALLOW_WINDLL := KERNEL32|SHELL32|SHLWAPI|api-ms-win-crt|ntdll|msvcrt
ALLOW_windows_lib := $(ALLOW_WINDLL)
ALLOW_windows_exe := $(ALLOW_WINDLL)
ALLOW_windows_njoy := $(ALLOW_WINDLL)
# $1=バイナリ $2=種別(lib/exe/njoy)
assert = d=$$($(call DEPS_$(OS),$1)); echo "== deps of $(notdir $1) =="; echo "$$d"; ! echo "$$d" | grep -Eiv '$(ALLOW_$(OS)_$2)' | grep -q . || { echo "unexpected shared dependency in $(notdir $1)"; exit 1; }
ASSERT_ALL = $(call assert,$(SHLIB_OUT),lib); $(call assert,$(OPENMC_EXE),exe); $(call assert,$(NJOY_EXE),njoy)

# 上流は全部 submodule。openmc は full clone (タグが入り CMake の GetVersionFromGit が動く。
# shallow だと openmc --version が 0.0.0 になる)。パッチの当て先はファイル名の最初の '-' より前。
# --force が submodule の作業ツリーを毎回 pristine に戻す (実測) ので、適用済み判定は要らない。
# その代わり src/ 以下を手で編集しても次の source で消える (パッチを足すのが正規の手順)。
# sort: 同じ submodule に複数当たるものがあるので適用順を固定する。
# .PHONY は使わないので段名は直下の実体と衝突させない (src/ があるため段名は src ではなく source)。
source:
	git submodule update --init --recursive --force
	find src -maxdepth 1 -name '*.patch' | sort | xargs -IX sh -c 'patch -p1 -d src/$$(basename X | cut -d- -f1) < X'

# 静的 (BUILD_SHARED_LIBS=OFF) にして Windows の DLL シンボル export 問題を丸ごと回避する。
# OpenMC は C API と HL のみ使うので C++/Fortran/tools は全部切る。
hdf5: source
	cmake -S src/hdf5 -B $(BUILD)/hdf5 $(CMAKE_COMMON) -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TESTING=OFF -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_TOOLS=OFF -DHDF5_BUILD_HL_LIB=ON -DHDF5_BUILD_CPP_LIB=OFF -DHDF5_BUILD_FORTRAN=OFF -DHDF5_ENABLE_THREADSAFE=OFF -DHDF5_ENABLE_SZIP_SUPPORT=OFF -DHDF5_ENABLE_ZLIB_SUPPORT=OFF
	cmake --build $(BUILD)/hdf5 -j $(JOBS)
	cmake --install $(BUILD)/hdf5

# .h5m は MOAB のファイル形式そのもので DAGMC はその上の薄い層。静的にするのが肝: 共有だと
# MSVC 構文のフラグ (/DMOAB_DLL) が GCC に渡り落ちる。既定 ON で落ちるものは明示的に切る。
moab: hdf5
	cmake -S src/moab -B $(BUILD)/moab $(CMAKE_COMMON) -DBUILD_SHARED_LIBS=OFF -DENABLE_HDF5=ON -DHDF5_ROOT=$(PREFIX) $(HDF5_STATIC_ARG) -DENABLE_BLASLAPACK=OFF -DENABLE_FORTRAN=OFF -DENABLE_TESTING=OFF -DENABLE_PYMOAB=OFF -DENABLE_NETCDF=OFF -DENABLE_MPI=OFF -DENABLE_METIS=OFF -DENABLE_ZOLTAN=OFF -DENABLE_PARMETIS=OFF -DENABLE_TEMPESTREMAP=OFF -DENABLE_CGNS=OFF -DENABLE_CPM=OFF
	cmake --build $(BUILD)/moab -j $(JOBS)
	cmake --install $(BUILD)/moab

# UWUW と TALLY は既定 ON だが OpenMC は使わない (UWUW は PyNE を引き込むので特に切る)。
# DAGMCConfig.cmake は install prefix を焼き込むので最終位置に直接入れる。
dagmc: moab
	cmake -S src/dagmc -B $(BUILD)/dagmc $(CMAKE_COMMON) -DMOAB_DIR=$(PREFIX) -DHDF5_ROOT=$(PREFIX) $(HDF5_STATIC_ARG) -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_UWUW=OFF -DBUILD_TALLY=OFF -DBUILD_BUILD_OBB=OFF -DBUILD_MAKE_WATERTIGHT=OFF -DBUILD_OVERLAP_CHECK=OFF -DBUILD_TESTS=OFF -DBUILD_CI_TESTS=OFF -DBUILD_EXE=OFF -DBUILD_STATIC_EXE=OFF -DBUILD_RPATH=OFF -DDOUBLE_DOWN=OFF -DPULL_INSTALL_MOAB=OFF
	cmake --build $(BUILD)/dagmc -j $(JOBS)
	cmake --install $(BUILD)/dagmc

# openmc.data.IncidentNeutron.from_njoy() が PATH 上の literal 'njoy' を Popen するので
# openmc(.exe) と同じ .data/scripts 同梱で成立する。install ターゲットが無いので build dir から cp。
# CMAKE_COMMON は使わない (Fortran 専用で C/C++・install prefix・PIC のどれも不要)。
# Python3_EXECUTABLE: ホストの python は Microsoft Store のスタブなので uv 管理のものを名指す
# (Windows ホストでは uv がバックスラッシュで返すので cmake に渡す前にスラッシュへ直す)。
njoy: source
	cmake -S src/njoy -B $(BUILD)/njoy -DCMAKE_BUILD_TYPE=Release -DCMAKE_Fortran_COMPILER=$(FC) -DPython3_EXECUTABLE=$(subst \,/,$(shell uv python find)) "-DCMAKE_EXE_LINKER_FLAGS=$(NJOY_STATIC)"
	cmake --build $(BUILD)/njoy -j $(JOBS) --target njoy_executable
	mkdir -p $(OUT)
	cp $(BUILD)/njoy/njoy$(EXE) $(NJOY_EXE)

# OPENMC_STATIC_LIB=ON (src/openmc-static-lib.patch) で libopenmc を静的にし exe を自己完結にする。
# DLL と exe を同じビルドでリンクすると MinGW の全シンボル自動エクスポートで _Unwind_Resume が
# exe 側の静的 libgcc_eh.a と multiple definition になる (実測) ので、ビルドディレクトリごと分ける。
openmc-exe: hdf5 dagmc
	cmake -S src/openmc -B $(BUILD)/openmc-exe $(OPENMC_CMAKE) $(OPENMP_STATIC) -DOPENMC_STATIC_LIB=ON "-DCMAKE_EXE_LINKER_FLAGS=$(RUNTIME_STATIC)"
	cmake --build $(BUILD)/openmc-exe -j $(JOBS)
	cmake --install $(BUILD)/openmc-exe
	mkdir -p $(OUT)
	cp $(PREFIX)/bin/openmc* $(OUT)/

# gcc-toolset (linux) の libgomp.a は非 PIC (TLS 再配置 R_X86_64_TPOFF32) で .so に畳めない (実測)
# ため linux の共有 lib は動的 libgomp のままにし、auditwheel repair に同梱させる。
OPENMP_SHARED = $(if $(filter linux,$(OS)),,$(OPENMP_STATIC))
# --exclude-libs,ALL: 静的 archive 由来のシンボル (H5*/MOAB/pugixml/fmt) を .so からエクスポート
# しない。しないと同一プロセスの h5py が持つ別ビルドの HDF5 と ELF のシンボル介入が起き
# openmc_init が segfault する (実測)。PE と Mach-O は構造的に介入が無いので不要。
LDFLAGS_SHARED_linux := -Wl,--exclude-libs,ALL
LDFLAGS_SHARED = $(strip $(RUNTIME_STATIC) $(LDFLAGS_SHARED_$(OS)))

openmc-lib: hdf5 dagmc
	cmake -S src/openmc -B $(BUILD)/openmc-lib $(OPENMC_CMAKE) $(OPENMP_SHARED) "-DCMAKE_SHARED_LINKER_FLAGS=$(LDFLAGS_SHARED)"
	cmake --build $(BUILD)/openmc-lib -j $(JOBS) --target libopenmc
	test -f $(SHLIB)
	mkdir -p $(OUT)
	cp $(SHLIB) $(SHLIB_OUT)

# タグは py3-none-<plat> (hatch_build.py が OPENMC_ANYWHERE_PLAT から組む)。python パッケージは
# pure Python なので CPython バージョン別の wheel は要らない。自己完結の断言をここで落とすことが
# プラットフォームタグの根拠になる (windows の objdump 断言はホスト検証と同じ check 側に置く)。
wheel: openmc-exe openmc-lib njoy
	OPENMC_ANYWHERE_PLAT=$(PLAT_BUILD) OPENMC_ANYWHERE_OUT=out/$(TARGET) OPENMC_ANYWHERE_SOEXT=$(SOEXT) OPENMC_ANYWHERE_NJOY=$(NJOY_EXE) uv build --wheel --out-dir dist
	$(if $(filter windows,$(OS)),true,$(ASSERT_ALL))
	$(if $(filter linux,$(OS)),for w in dist/openmc_anywhere-*-py3-none-$(PLAT_BUILD).whl; do auditwheel repair --plat $(PLAT) -w dist $$w && rm $$w; done,true)
	ls -1 $(WHEEL_GLOB) | tail -1

path: ## 完成 wheel のパスを stdout に出す (ビルドしない)
	ls -1 $(WHEEL_GLOB) | tail -1

# windows の断言2つ: DLL の import がシステム DLL のみ (自己完結の証明) と、openmc_init を
# エクスポート (ctypes が読める形の証明)。PATH に venv の bin を前置するのが肝 — python を直接
# 叩くだけでは PATH に乗らず、上流 executor.py の literal 'openmc' 解決が失敗する。
# check.py の生成物を捨てるため使い捨てディレクトリへ cd するので、そこから先だけ絶対パスが要る。
# しかも PATH と引数で必要な形式が違う (Windows ホストのみ。実測):
#   PATH は MSYS 形式 ($OLDPWD = /c/...)。`C:/...` を ':' で連結すると MSYS の PATH 変換が
#   失敗して前置が丸ごと消え、shutil.which('openmc') が None になる。
#   引数は Windows 形式 ($(abspath))。1行目の MSYS_NO_PATHCONV=1 が引数のパス変換を止めて
#   いるので、/c/... を渡すと native python が C:\c\... と解釈して開けない。
check:
	$(if $(filter windows,$(OS)),$(call assert,$(SHLIB_OUT),lib); $(call assert,$(NJOY_EXE),njoy); objdump -p $(SHLIB_OUT) | grep -q openmc_init,true)
	uv venv venv-check --python 3.12 --allow-existing
	uv pip install --python venv-check --reinstall $$(ls -1 $(WHEEL_GLOB) | tail -1)
	rm -rf $(BUILD)/check-run
	mkdir -p $(BUILD)/check-run
	cd $(BUILD)/check-run && PATH="$$OLDPWD/$(VENV_BIN):$$PATH" $$OLDPWD/$(VENV_BIN)/python$(EXE) $(abspath check.py) $(abspath src/openmc/tests/regression_tests/dagmc/legacy/dagmc.h5m)
## B
cross-%: ## docker/Dockerfile_<triple> の toolchain イメージ内で wheel をビルド
	docker build -f docker/Dockerfile_$* -t cross-$* .
	docker run --rm -v $(CURDIR):/io -w /io cross-$* bash -c "git config --global --add safe.directory '*' && make wheel TARGET=$*"
	$(MAKE) --no-print-directory path TARGET=$*

check: ## ローカル検証 (核データ不要) e.g. make cross-x86_64-pc-windows-gnu && make check

clean: ## ビルド成果物を削除する
	rm -rf build prefix out dist venv-check

help: ## ヘルプを表示する
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
