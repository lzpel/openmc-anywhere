export MSYS_NO_PATHCONV=1

# cross-% / CI / docker が TARGET を上書きする。
TARGET ?= $(shell uname -m | sed 's/arm64/aarch64/')-$(shell uname -s | sed -e 's/Darwin/apple-darwin/' -e 's/Linux/unknown-linux-gnu/' -e 's/^\(MINGW\|MSYS\|CYGWIN\).*/pc-windows-gnu/')

# 環境の事実 (コンパイラ・SDK・toolchain) は docker/Dockerfile_<triple> の ENV に閉じる。
# ここは TARGET から一意に決まる方針だけを持ち、全て同名の環境変数で上書きできる。
OS := $(if $(findstring windows,$(TARGET)),windows,$(if $(findstring apple,$(TARGET)),darwin,linux))
ARCH := $(firstword $(subst -, ,$(TARGET)))

# ここだけ絶対パス。LINK_TAIL の .a は cmake が相対のままリンク行へ通すが、
# リンクは cwd=ビルドディレクトリで走るので解決できない (実測)。
export CMAKE_PREFIX_PATH := $(abspath out/$(TARGET))
# cmake --build は -j 省略時にこの環境変数を読む (cmake >= 3.12) ので各段から -j が消える。
export CMAKE_BUILD_PARALLEL_LEVEL ?= 8

# 3 OS で値が割れるものは OS をキーにした表、1 OS だけ他と違うものは $(if) で書く。
SOEXT_windows := dll
SOEXT_darwin := dylib
SOEXT_linux := so
SOEXT := $(SOEXT_$(OS))
EXE := $(if $(filter windows,$(OS)),.exe)

# linux はまず素の linux_<arch> で作り auditwheel repair が manylinux に retag する。
PLAT_windows := win_amd64
PLAT_darwin := macosx_11_0_$(subst aarch64,arm64,$(ARCH))
PLAT_linux := manylinux_2_28_$(ARCH)
PLAT := $(PLAT_$(OS))
PLAT_BUILD := $(if $(filter linux,$(OS)),linux_$(ARCH),$(PLAT))

# windows は -static で libstdc++/libgcc/libwinpthread まで畳める。darwin はシステム
# libc++/libSystem が全 macOS にあるので不要。linux は glibc 動的 = manylinux の前提。
RUNTIME_STATIC_windows := -static
RUNTIME_STATIC_linux := -static-libgcc -static-libstdc++
RUNTIME_STATIC ?= $(RUNTIME_STATIC_$(OS))

# FindHDF5 は既定で .so を探すので静的のみの install には明示が要る。MinGW では .a が
# import-lib の拡張子でもあり、渡すとリンク順が変わって H5Aopen_name が未解決になる (実測)。
HDF5_STATIC_ARG ?= $(if $(filter windows,$(OS)),,-DHDF5_USE_STATIC_LIBRARIES=ON)

# 単一パスの ld ではリンク行が libhdf5.a ... libMOAB.a の順になり mhdf の H5Aopen_name /
# H5Fis_hdf5 だけ未解決になる (実測)。行末に付く変数で HDF5 を再掲して閉じる。
LINK_TAIL ?= $(if $(filter linux,$(OS)),"-DCMAKE_CXX_STANDARD_LIBRARIES=$(CMAKE_PREFIX_PATH)/lib/libhdf5_hl.a $(CMAKE_PREFIX_PATH)/lib/libhdf5.a")

# gcc-toolset-14 に libgfortran.a / libquadmath.a がある (実測)。-static-libquadmath は GCC>=13。
# darwin の flang の畳み方は docker ENV の NJOY_STATIC 側で調整する。
NJOY_STATIC_windows := -static
NJOY_STATIC_linux := -static-libgfortran -static-libquadmath -static-libgcc
NJOY_STATIC ?= $(NJOY_STATIC_$(OS))

# FindOpenMP が渡す import ライブラリの絶対パスは -static で覆せず動的リンクが残るので、
# 静的版を名指しする。名前は GCC 系が gomp、clang 系 (darwin) が omp で ENV が注入する。
OPENMP_LIB_NAME ?= gomp
OPENMP_LIB ?= $(shell $(CXX) -print-file-name=lib$(OPENMP_LIB_NAME).a)
# FindOpenMP は FLAGS と LIB_NAMES の両方が事前設定のときだけ try_compile 検出を飛ばす。
# osxcross の aarch64 は検出が落ちる (CI run 29983656072) ので ENV の OPENMP_FLAGS で回避。
OPENMP_STATIC = -DOpenMP_CXX_LIB_NAMES=$(OPENMP_LIB_NAME) -DOpenMP_C_LIB_NAMES=$(OPENMP_LIB_NAME) -DOpenMP_$(OPENMP_LIB_NAME)_LIBRARY=$(OPENMP_LIB) $(if $(OPENMP_FLAGS),-DOpenMP_C_FLAGS=$(OPENMP_FLAGS) -DOpenMP_CXX_FLAGS=$(OPENMP_FLAGS))

# PIC は linux で静的 archive を libopenmc.so に畳むのに必須 (PE では no-op)。
CMAKE_COMMON := -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=$(CMAKE_PREFIX_PATH)
OPENMC_CMAKE := $(CMAKE_COMMON) -DHDF5_PREFER_PARALLEL=FALSE -DOPENMC_BUILD_TESTS=OFF -DOPENMC_FORCE_VENDORED_LIBS=ON -DOPENMC_USE_DAGMC=ON $(HDF5_STATIC_ARG) $(LINK_TAIL)

# 上流 POST_BUILD の落とし先は全 TARGET 共有で同 OS の 2 arch が同名衝突するため、
# per-target の out/$(TARGET)/wheel/ へ退避する。hatch_build.py はそちらを拾う。
# out/$(TARGET)/ 直下は段名 (hdf5 moab dagmc njoy openmc-exe openmc-lib check-run) の
# cmake ビルドディレクトリと $(CMAKE_PREFIX_PATH) の install レイアウトなので wheel/ を挟む。直下に
# 置くと linux/darwin は EXE が空で njoy 実行ファイルが同名のビルドディレクトリと衝突し、
# cp がその中へ潜る (bin/openmc とも紛らわしい)。
SHLIB := src/openmc/openmc/lib/libopenmc.$(SOEXT)
SHLIB_OUT := out/$(TARGET)/wheel/libopenmc.$(SOEXT)
OPENMC_EXE := out/$(TARGET)/wheel/openmc$(EXE)
NJOY_EXE := out/$(TARGET)/wheel/njoy$(EXE)
WHEEL_GLOB := dist/openmc_anywhere-*-py3-none-$(PLAT).whl
VENV_BIN := venv-check/$(if $(filter windows,$(OS)),Scripts,bin)

# ---- 自己完結の断言。許可リストに載らない動的依存が1つでも残っていたら失敗させる ----
# ALLOW_* は行末コメントの手前の空白が値に残る (make の仕様) ので $(strip) してから渡す。
# 付いたままだと最後の選択肢が "msvcrt " になり msvcrt.dll を弾いて落ちる (実測)。
DEPS_linux = ldd $1 | grep '=>' | sed 's/=>.*//' | tr -d ' \t'
DEPS_darwin = $(OTOOL) -L $1 | tail -n +2 | sed -n 's/^[[:space:]]*\([^[:space:]]*\).*compatibility.*/\1/p'
DEPS_windows = objdump -p $1 | sed -n 's/.*DLL Name: *//p'
ALLOW_linux := linux-vdso|libc\.|libm\.|libpthread|libdl|librt|ld-linux|libgomp|libmvec 
ALLOW_darwin := libopenmc|/usr/lib/ # 許すのは自分自身の install name と /usr/lib のみ。@rpath が残っていたら壊れている。
ALLOW_windows := KERNEL32|SHELL32|SHLWAPI|api-ms-win-crt|ntdll|msvcrt # SHLWAPI は HDF5 が Win32 API 経由で使う、全 Windows に存在する DLL。
# 空リストは許可リスト検査を素通りするので明示的に落とす。
assert = d=$$($(call DEPS_$(OS),$1)); echo "== deps of $(notdir $1) =="; echo "$$d"; test -n "$$d" || { echo "no shared dependency read from $(notdir $1)"; exit 1; }; ! echo "$$d" | grep -Eiv '$(strip $(ALLOW_$(OS)))' | grep -q . || { echo "unexpected shared dependency in $(notdir $1)"; exit 1; }
ASSERT_ALL = $(call assert,$(SHLIB_OUT)); $(call assert,$(OPENMC_EXE)); $(call assert,$(NJOY_EXE))

# 自己完結の断言をここで落とすことがプラットフォームタグの根拠になる
# (windows の objdump 断言はホスト検証と同じ check 側)。
wheel: openmc-exe openmc-lib njoy
	OPENMC_ANYWHERE_PLAT=$(PLAT_BUILD) OPENMC_ANYWHERE_OUT=out/$(TARGET)/wheel OPENMC_ANYWHERE_SOEXT=$(SOEXT) OPENMC_ANYWHERE_NJOY=$(NJOY_EXE) uv build --wheel --out-dir dist
	$(if $(filter windows,$(OS)),,$(ASSERT_ALL))
	$(if $(filter linux,$(OS)),for w in dist/openmc_anywhere-*-py3-none-$(PLAT_BUILD).whl; do auditwheel repair --plat $(PLAT) -w dist $$w && rm $$w; done)
	ls -1 $(WHEEL_GLOB) | tail -1

# --force が submodule を毎回 pristine に戻す (実測) ので適用済み判定は不要。src/ の手編集は消える。
# sort は openmc の 4 パッチが同じ CMakeLists.txt を触るため。段名 source は src/ との衝突回避。
source:
	git submodule update --init --recursive --force
	find src -maxdepth 1 -name '*.patch' | sort | xargs -IX sh -c 'patch -p1 -d src/$$(basename X | cut -d- -f1) < X'

# 静的にして Windows の DLL シンボル export 問題を丸ごと回避する。
# 上流の既定と同じ値のフラグは渡さない (cmake の既定に任せる)。以下の各段も同様。
hdf5: source
	cmake -S src/hdf5 -B out/$(TARGET)/hdf5 $(CMAKE_COMMON) -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_TOOLS=OFF
	cmake --build out/$(TARGET)/hdf5 --target install

# 静的が肝 — 共有だと MSVC 構文のフラグ (/DMOAB_DLL) が GCC に渡って落ちる。
moab: hdf5
	cmake -S src/moab -B out/$(TARGET)/moab $(CMAKE_COMMON) -DBUILD_SHARED_LIBS=OFF -DENABLE_HDF5=ON $(HDF5_STATIC_ARG) -DENABLE_BLASLAPACK=OFF -DENABLE_FORTRAN=OFF -DENABLE_TESTING=OFF
	cmake --build out/$(TARGET)/moab --target install

# UWUW と TALLY は既定 ON。UWUW は PyNE を引き込む。
# DAGMCConfig.cmake は install prefix を焼き込むので最終位置に直接入れる。
# MOAB_DIR だけ残るのは、上流 cmake/FindMOAB.cmake が find_path を NO_DEFAULT_PATH で
# 呼び ${MOAB_DIR}/lib*/cmake/MOAB しか見ないため。CMAKE_PREFIX_PATH は届かない。
dagmc: moab
	cmake -S src/dagmc -B out/$(TARGET)/dagmc $(CMAKE_COMMON) -DMOAB_DIR=$(CMAKE_PREFIX_PATH) $(HDF5_STATIC_ARG) -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_UWUW=OFF -DBUILD_TALLY=OFF -DBUILD_BUILD_OBB=OFF -DBUILD_MAKE_WATERTIGHT=OFF -DBUILD_OVERLAP_CHECK=OFF -DBUILD_TESTS=OFF -DBUILD_EXE=OFF -DBUILD_RPATH=OFF
	cmake --build out/$(TARGET)/dagmc --target install

# 上流は PATH 上の literal 'njoy' を Popen するので openmc(.exe) と同じ同梱で成立する。
# install ターゲットが無いので build dir から cp。uv の python は Windows で \ を返すので直す。
njoy: source
	cmake -S src/njoy -B out/$(TARGET)/njoy -DCMAKE_BUILD_TYPE=Release -DPython3_EXECUTABLE=$(subst \,/,$(shell uv python find)) "-DCMAKE_EXE_LINKER_FLAGS=$(NJOY_STATIC)"
	cmake --build out/$(TARGET)/njoy --target njoy_executable
	mkdir -p out/$(TARGET)/wheel
	cp out/$(TARGET)/njoy/njoy$(EXE) $(NJOY_EXE)

# exe と DLL を同じビルドでリンクすると MinGW の全シンボル自動エクスポートで _Unwind_Resume が
# 静的 libgcc_eh.a と multiple definition になる (実測) ため、ビルドディレクトリごと分ける。
openmc-exe: hdf5 dagmc
	cmake -S src/openmc -B out/$(TARGET)/openmc-exe $(OPENMC_CMAKE) $(OPENMP_STATIC) -DOPENMC_STATIC_LIB=ON "-DCMAKE_EXE_LINKER_FLAGS=$(RUNTIME_STATIC)"
	cmake --build out/$(TARGET)/openmc-exe --target install
	mkdir -p out/$(TARGET)/wheel
	cp $(CMAKE_PREFIX_PATH)/bin/openmc* out/$(TARGET)/wheel/

# gcc-toolset の libgomp.a は非 PIC (TLS 再配置 R_X86_64_TPOFF32) で .so に畳めない (実測)。
# linux だけ動的 libgomp のままにし、auditwheel repair に同梱させる。
OPENMP_SHARED = $(if $(filter linux,$(OS)),,$(OPENMP_STATIC))
# --exclude-libs,ALL: 静的 archive のシンボルを .so から出さない。出すと同一プロセスの h5py が
# 持つ別ビルドの HDF5 と ELF のシンボル介入が起き openmc_init が segfault する (実測)。
LDFLAGS_SHARED_linux := -Wl,--exclude-libs,ALL
LDFLAGS_SHARED = $(strip $(RUNTIME_STATIC) $(LDFLAGS_SHARED_$(OS)))

openmc-lib: hdf5 dagmc
	cmake -S src/openmc -B out/$(TARGET)/openmc-lib $(OPENMC_CMAKE) $(OPENMP_SHARED) "-DCMAKE_SHARED_LINKER_FLAGS=$(LDFLAGS_SHARED)"
	cmake --build out/$(TARGET)/openmc-lib --target libopenmc
	mkdir -p out/$(TARGET)/wheel
	cp $(SHLIB) $(SHLIB_OUT)

path: ## 完成 wheel のパスを stdout に出す (ビルドしない)
	ls -1 $(WHEEL_GLOB) | tail -1

# cd 先から使うパスは形式が割れる (Windows。実測)。PATH は MSYS 形式でないと変換に失敗して
# 前置が消え、引数は MSYS_NO_PATHCONV=1 のため Windows 形式でないと native python が開けない。
check: ## ローカル検証 (核データ不要) e.g. make cross-x86_64-pc-windows-gnu && make check
	$(if $(filter windows,$(OS)),$(call assert,$(SHLIB_OUT)); $(call assert,$(NJOY_EXE)); objdump -p $(SHLIB_OUT) | grep -q openmc_init)
	uv venv venv-check --python 3.12 --allow-existing
	uv pip install --python venv-check --reinstall $$(ls -1 $(WHEEL_GLOB) | tail -1)
	rm -rf out/$(TARGET)/check-run
	mkdir -p out/$(TARGET)/check-run
	cd out/$(TARGET)/check-run && PATH="$$OLDPWD/$(VENV_BIN):$$PATH" $$OLDPWD/$(VENV_BIN)/python$(EXE) $(abspath check.py) $(abspath src/openmc/tests/regression_tests/dagmc/legacy/dagmc.h5m)

cross-%: ## docker/Dockerfile_<triple> の toolchain イメージ内で wheel をビルド
	docker build -f docker/Dockerfile_$* -t cross-$* .
	docker run --rm -v $(CURDIR):/io -w /io cross-$* bash -c "git config --global --add safe.directory '*' && make wheel TARGET=$*"
	$(MAKE) --no-print-directory path TARGET=$*

clean: ## ビルド成果物を削除する
	rm -rf out dist venv-check

help: ## ヘルプを表示する
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
