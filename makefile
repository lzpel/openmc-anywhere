# openmc-pypi: OpenMC の PyPI 形式バイナリ wheel を作る。`uv add openmc-pypi` だけで
# 公式 OpenMC のコードが Windows / Linux でそのまま動く (openmc 実行ファイル + libopenmc
# 共有ライブラリ同梱、DAGMC 込み) ことをゴールにする。ビルド手順・パッチは
# mhd-tbr-stell/sandbox-openmc-source (MinGW ネイティブビルドの実証) からの移植。
#
#   make            # (デフォルト) このOSの wheel をビルドし、そのパスを stdout に印字
#   make check      # wheel を venv に入れて end-to-end 検証 (check.py の3経路)
#   make linux      # Docker の manylinux コンテナで Linux wheel をビルド
#   make check-linux# 素の python:3.12 コンテナで Linux wheel を検証 (可搬性の証明)
#   make clean      # build/ prefix/ out/ dist/ venv-check/ を削除
#
# 中間ディレクトリは OS ごとに分離する (build/windows と build/linux など)。src/ の
# submodule とその中のソースツリーだけは両 OS で共有し、libopenmc.{dll,so} は上流 CMake の
# POST_BUILD コピーで src/openmc/openmc/lib/ に落ちる (wheel が拾う場所。ファイル名が
# OS で違うので衝突しない)。

# Git Bash が cmake の引数中の Windows パス (-DCMAKE_INSTALL_PREFIX=C:/... など) を
# MSYS パスへ勝手に変換するのを防ぐ (sandbox-openmc-source と同じ対処。Linux では無害)。
export MSYS_NO_PATHCONV=1

HDF5_VER   ?= 2.1.1
MOAB_VER   ?= 5.6.0
DAGMC_REF  ?= v3.2.4
JOBS       ?= 8

# windows (ホスト) / linux (make linux が docker 内で上書き)
OSNAME ?= windows

SRC    := $(CURDIR)/src
BUILD  := $(CURDIR)/build/$(OSNAME)
PREFIX := $(CURDIR)/prefix/$(OSNAME)
OUT    := $(CURDIR)/out/$(OSNAME)

# ?= ではなく = にすること。GNU Make は CC/CXX に組み込みデフォルト (cc /
# x86_64-w64-mingw32-g++) を持っており、?= だと「定義済み」扱いで発火せず、
# 存在しない cc を掴んで configure が落ちる。= ならコマンドライン指定は依然優先される。
CC     = gcc
CXX    = g++

# CMake の FindOpenMP は libgomp を「インポートライブラリの絶対パス」
# (.../libgomp.dll.a) として渡してくる。絶対パス指定は -static では覆せないので、
# そのままだと libgomp-1.dll (Linux では libgomp.so.1) への動的リンクが残り
# スタンドアローン性が壊れる。静的版を名指しして上書きする。
OPENMP_LIB ?= $(shell $(CXX) -print-file-name=libgomp.a)

# OS ごとのリンクフラグと wheel プラットフォームタグ。
#   windows: -static 一発で libstdc++/libgcc/libwinpthread まで全部畳める (exe で実測済み)。
#   linux:   glibc は manylinux の前提なので動的のまま、gcc ランタイムだけ静的にする。
#            wheel タグは manylinux_2_28 (ビルドを quay.io/pypa/manylinux_2_28 で行い、
#            glibc 以外への動的依存を linux-inner の ldd 検査で排除することが根拠)。
ifeq ($(OSNAME),windows)
  RUNTIME_STATIC = -static
  PLAT           = win_amd64
  EXE            = $(OUT)/openmc.exe
  SHLIB          = $(SRC)/openmc/openmc/lib/libopenmc.dll
  LINK_TAIL      =
else
  RUNTIME_STATIC = -static-libgcc -static-libstdc++
  PLAT           = manylinux_2_28_x86_64
  EXE            = $(OUT)/openmc
  SHLIB          = $(SRC)/openmc/openmc/lib/libopenmc.so
  # CMake が組むリンク行は ...libhdf5.a ... libMOAB.a の順になり、単一パスの ld では
  # MOAB の mhdf が使う deprecated API (H5Aopen_name / H5Fis_hdf5) だけが未解決になる
  # (他の H5 シンボルは libopenmc が先に引き込んだオブジェクトで偶然足りる。実測)。
  # CMAKE_CXX_STANDARD_LIBRARIES は全 exe/共有 lib のリンク行末尾に付くので、HDF5 を
  # 再掲して閉じる。Linux の既定値は空なので上書きしても何も失わない
  # (Windows は -lkernel32 等の既定があるため触らない。MinGW では元の順で通っている)。
  LINK_TAIL      = -DCMAKE_CXX_STANDARD_LIBRARIES="$(PREFIX)/lib/libhdf5_hl.a $(PREFIX)/lib/libhdf5.a"
  # wheel はまず素の linux_x86_64 タグで作り、auditwheel repair が libgomp.so.1 を
  # 同梱して manylinux_2_28 に retag する (下記 OPENMP_ARGS_LIB 参照)。
  PLAT_BUILD     = linux_x86_64
  # Linux の FindHDF5 は既定で .so を探すため、静的のみのインストールだと
  # HDF5_LIBRARIES が見つからず configure が落ちる (実測、moab で発生)。
  # Windows に渡してはいけない: MinGW では .a が import-lib の拡張子でもあるため
  # 指定なしで通っており、指定するとリンク順が変わって MOAB の deprecated API
  # (H5Aopen_name) が未解決になる (実測)。
  HDF5_STATIC_ARG = -DHDF5_USE_STATIC_LIBRARIES=ON
endif
PLAT_BUILD ?= $(PLAT)

# 検証用の断面積とデータ。wheel には焼き込まない (利用者が OPENMC_CROSS_SECTIONS で渡す)。
XSDIR ?= C:/Users/smith/mhd-tbr-stell/sandbox-openmc/data
XS    ?= $(XSDIR)/lib/cross_sections.xml
H5M   := $(SRC)/openmc/tests/regression_tests/dagmc/legacy/dagmc.h5m

# patches/*.patch を全部当てる。適用済みなら黙って飛ばす (.PHONY なので毎回このレシピに
# 入るため、--reverse --check が通る = すでに当たっている、という判定にする)。
# $(1)=patches/ 配下のサブディレクトリ名, $(2)=当て先のソースツリー。
APPLY_PATCHES = for p in $$(ls $(CURDIR)/patches/$(1)/*.patch 2>/dev/null | sort); do \
	  if patch -p1 -d $(2) -R --dry-run -s -f < "$$p" >/dev/null 2>&1; then \
	    echo "$(1)/$$(basename $$p): already applied" >&2; \
	  else \
	    patch -p1 -d $(2) < "$$p" $(E) || exit 1; \
	    echo "$(1)/$$(basename $$p): applied" >&2; \
	  fi; \
	done

HDF5_URL   = https://github.com/HDFGroup/hdf5/releases/download/$(HDF5_VER)/hdf5-$(HDF5_VER).tar.gz
# tarball ではなく git を使う。配布 tarball は autotools の `make dist` 産物で、CMake 用の
# config/{logging,dist,distcheck}.cmake が EXTRA_DIST から漏れており configure が落ちる。
MOAB_URL   = https://bitbucket.org/fathomteam/moab.git
DAGMC_URL  = https://github.com/svalinn/DAGMC.git

# -DCMAKE_POSITION_INDEPENDENT_CODE=ON: hdf5/moab/dagmc の静的 archive は Linux で
# libopenmc.so に畳まれるので PIC が必須。Windows (PE) では無害な no-op。
CMAKE_COMMON = -DCMAKE_BUILD_TYPE=Release \
               -DCMAKE_C_COMPILER=$(CC) -DCMAKE_CXX_COMPILER=$(CXX) \
               -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
               -DCMAKE_INSTALL_PREFIX=$(PREFIX)

# 全ビルド出力を 1>&2 に流すのは、デフォルトターゲットが stdout に wheel のパスだけを
# 出す必要があるため (sandbox-openfoam/epotFoam 以来のイディオム)。
E = 1>&2

.PHONY: default src hdf5 moab dagmc openmc-exe openmc-lib wheel check linux linux-inner check-linux clean

# ---- デフォルト: wheel をビルドし、そのパスだけを stdout に出す ----
default: wheel
	@ls dist/openmc_pypi-*-$(PLAT).whl

# ================= 段0: ソース =================
# submodule は full clone なのでタグも入り、CMake の GetVersionFromGit がそのまま動く
# (shallow だと openmc --version が 0.0.0 になる)。
src:
	@git submodule update --init --recursive $(E)
	@$(call APPLY_PATCHES,openmc,$(SRC)/openmc)

# ================= 段1: HDF5 =================
# 静的 (BUILD_SHARED_LIBS=OFF) にして Windows の DLL シンボル export 問題を丸ごと回避する。
# OpenMC は C API と HL のみ使うので C++/Fortran/tools は全部切る。zlib は HDF5 2.x の既定通り OFF。
hdf5:
	@command -v cmake >/dev/null \
	  || { echo "cmake not found in PATH; install it and retry" >&2; exit 1; }
	@mkdir -p $(SRC)
	@test -f $(SRC)/hdf5-$(HDF5_VER)/CMakeLists.txt \
	  || (cd $(SRC) && curl -fL -o hdf5.tar.gz $(HDF5_URL) $(E) \
	      && tar xzf hdf5.tar.gz && rm -f hdf5.tar.gz)
	cmake -S $(SRC)/hdf5-$(HDF5_VER) -B $(BUILD)/hdf5 $(CMAKE_COMMON) \
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
moab:
	@mkdir -p $(SRC)
	@test -d $(SRC)/moab/.git \
	  || git clone --branch $(MOAB_VER) --depth 1 $(MOAB_URL) $(SRC)/moab $(E)
	@$(call APPLY_PATCHES,moab,$(SRC)/moab)
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
	@test -d $(SRC)/dagmc/.git \
	  || git clone --recurse-submodules --branch $(DAGMC_REF) --depth 1 \
	       $(DAGMC_URL) $(SRC)/dagmc $(E)
	@$(call APPLY_PATCHES,dagmc,$(SRC)/dagmc)
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

# ================= 段2a: openmc 実行ファイル (libopenmc 静的) =================
# OPENMC_STATIC_LIB=ON (patches/openmc/static-lib.patch) で libopenmc を静的にし、
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

# 静的 libgomp の名指し (根拠は OPENMP_LIB のコメント)。exe は両OSで使える。共有 lib は
# Windows のみ: gcc-toolset の libgomp.a は非 PIC (TLS 再配置 R_X86_64_TPOFF32) で
# .so に畳めない (実測) ため、Linux の共有 lib は動的 libgomp のままにして
# auditwheel repair に同梱させる。
OPENMP_STATIC = -DOpenMP_CXX_LIB_NAMES=gomp -DOpenMP_C_LIB_NAMES=gomp \
	  -DOpenMP_gomp_LIBRARY="$(OPENMP_LIB)"
ifeq ($(OSNAME),windows)
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

openmc-exe: src hdf5 dagmc
	cmake -S $(SRC)/openmc -B $(BUILD)/openmc-exe $(OPENMC_CMAKE) $(OPENMP_STATIC) \
	  -DOPENMC_STATIC_LIB=ON \
	  -DCMAKE_EXE_LINKER_FLAGS="$(RUNTIME_STATIC)" $(E)
	cmake --build $(BUILD)/openmc-exe -j $(JOBS) $(E)
	cmake --install $(BUILD)/openmc-exe $(E)
	@mkdir -p $(OUT)
	cp $(PREFIX)/bin/openmc* $(OUT)/ $(E)

# ================= 段2b: libopenmc 共有ライブラリ (openmc.lib 用) =================
# SHARED でも -static (Linux は -static-libgcc -static-libstdc++) でランタイムを畳み、
# CDLL が絶対パスだけでロードできる自己完結な DLL/so にする。ビルドは libopenmc
# ターゲットのみ (exe をリンクしないので上記の multiple definition が構造的に起きない)。
# 出来上がりは上流 CMakeLists の POST_BUILD がソースツリー openmc/lib/ にコピーする
# (上流が python パッケージへ共有 lib を渡す正規の経路。wheel はそこから拾う)。
openmc-lib: src hdf5 dagmc
	cmake -S $(SRC)/openmc -B $(BUILD)/openmc-lib $(OPENMC_CMAKE) $(OPENMP_ARGS_LIB) \
	  -DCMAKE_SHARED_LINKER_FLAGS="$(SHLIB_LDFLAGS)" $(E)
	cmake --build $(BUILD)/openmc-lib -j $(JOBS) --target libopenmc $(E)
	@test -f $(SHLIB) || { echo "POST_BUILD copy did not produce $(SHLIB)" >&2; exit 1; }

# ================= 段3: wheel =================
# タグは py3-none-$(PLAT) (hatch_build.py が OPENMC_PYPI_PLAT から組む)。python パッケージは
# pure Python なので CPython バージョン別の wheel は要らない。
# uv は manylinux イメージにも同梱されているので両OSで同じコマンドが使える。
WHEEL_CMD = uv build --wheel --out-dir dist

wheel: openmc-exe openmc-lib
	OPENMC_PYPI_PLAT=$(PLAT_BUILD) $(WHEEL_CMD) $(E)

# ================= 検証 =================
# wheel を venv に入れ、check.py の3経路 (subprocess / openmc.lib / DAGMC) を通す。
# PATH に venv の Scripts を前置するのが肝: python.exe を直接叩くだけでは Scripts が
# PATH に乗らず、executor.py の literal 'openmc' 解決 (利用者が activate した状態の
# 再現) が失敗する。
# objdump の断言2つ: DLL の import が Windows 同梱のシステム DLL のみ (自己完結の証明。
# SHLWAPI は HDF5 が Win32 API 経由で使う、全 Windows に存在する DLL)、
# かつ openmc_init をエクスポート (ctypes が読める形の証明)。
check: wheel
	@echo "== DLL self-containment ==" >&2
	@objdump -p $(SHLIB) | grep "DLL Name" >&2 || true
	@! objdump -p $(SHLIB) | grep "DLL Name" | grep -viE "KERNEL32|SHELL32|SHLWAPI|api-ms-win-crt|ntdll|msvcrt" \
	  || { echo "unexpected DLL dependency" >&2; exit 1; }
	@objdump -p $(SHLIB) | grep -q openmc_init || { echo "openmc_init not exported" >&2; exit 1; }
	uv venv venv-check --python 3.12 --allow-existing $(E)
	uv pip install --python venv-check --reinstall dist/openmc_pypi-*-$(PLAT).whl $(E)
	@rm -rf $(BUILD)/check-run && mkdir -p $(BUILD)/check-run
	cd $(BUILD)/check-run && \
	  PATH="$$(cygpath -u $(CURDIR)/venv-check/Scripts):$$PATH" \
	  OPENMC_CROSS_SECTIONS="$(XS)" \
	  $(CURDIR)/venv-check/Scripts/python.exe $(CURDIR)/check.py $(H5M)

# ================= Linux (Docker) =================
# ビルドは manylinux_2_28 コンテナ内で同じ makefile を OSNAME=linux で回す。
# safe.directory: マウントした repo の所有者が container の root と食い違うため。
linux:
	docker run --rm -v $(CURDIR):/io -w /io quay.io/pypa/manylinux_2_28_x86_64 \
	  bash -c "git config --global --add safe.directory '*' && make linux-inner OSNAME=linux JOBS=$(JOBS)" $(E)
	@ls dist/openmc_pypi-*-manylinux*.whl

# コンテナ内: 素の linux_x86_64 タグで wheel を作り、auditwheel repair が libgomp.so.1 を
# 同梱 (openmc_pypi.libs/、RPATH 書き換え) して manylinux_2_28 に retag する。
# ldd 断言: exe は glibc のみ (libgomp は静的)。.so は glibc + libgomp のみ
# (libgomp は repair が畳む) で、それ以外の動的依存が紛れたら失敗させる。
linux-inner: wheel
	@echo "== ldd ==" >&2
	@ldd $(SHLIB) >&2
	@! ldd $(SHLIB) | grep -viE "linux-vdso|libc\.|libm\.|libpthread|libdl|librt|ld-linux|libgomp" | grep -q "=>" \
	  || { echo "unexpected shared dependency in libopenmc.so" >&2; exit 1; }
	@! ldd $(OUT)/openmc | grep -viE "linux-vdso|libc\.|libm\.|libpthread|libdl|librt|ld-linux" | grep -q "=>" \
	  || { echo "unexpected shared dependency in openmc" >&2; exit 1; }
	auditwheel repair --plat $(PLAT) -w dist dist/openmc_pypi-*-$(PLAT_BUILD).whl $(E)
	rm dist/openmc_pypi-*-$(PLAT_BUILD).whl

# 検証はビルドイメージではなく素の python:3.12 で行う (可搬性の証明)。データは読み取りで
# 足りるので :ro。check.py の生成物はコンテナ内 /tmp に落ちて廃棄される。
check-linux:
	docker run --rm -v $(CURDIR):/io:ro -v $(XSDIR):/data:ro \
	  -e OPENMC_CROSS_SECTIONS=/data/lib/cross_sections.xml python:3.12 \
	  bash -c "pip install -q /io/dist/openmc_pypi-*-manylinux*.whl \
	    && mkdir /tmp/run && cd /tmp/run \
	    && python /io/check.py /io/src/openmc/tests/regression_tests/dagmc/legacy/dagmc.h5m"

clean:
	rm -rf $(CURDIR)/build $(CURDIR)/prefix $(CURDIR)/out dist venv-check
