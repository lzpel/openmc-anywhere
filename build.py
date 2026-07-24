#!/usr/bin/env python3
"""openmc-anywhere の wheel を作る段取りの本体。

makefile はコマンドメニューに徹し (`uv run --no-project build.py <stage>` を呼ぶだけ)、
段の依存・cmake フラグ・自己完結の断言はすべてここに置く (issue #9。cadrum の build.rs
に相当する置き場)。実行は必ず `uv run --no-project` 経由にする — `--no-project` が無いと
uv が pyproject.toml の dependencies (numpy/h5py/...) を同期しに行く。標準ライブラリのみ。

  build.py <stage> --target <triple>   段を実行する (依存段は自動で先に走る)
      stage = src hdf5 moab dagmc njoy openmc-exe openmc-lib wheel
  build.py check  --target <triple>    wheel を venv に入れて check.py の4経路を通す
  build.py path   --target <triple>    完成 wheel のパスを stdout に出す (ビルドしない)

出力の規約: 全ビルドログは stderr に流し、stdout には wheel のパスだけを出す
(sandbox-openfoam/epotFoam 以来のイディオム。旧 makefile の `E = 1>&2` に相当)。

環境変数の契約: ターゲット環境依存の設定 (コンパイラ名・SDK・toolchain) は
docker/Dockerfile_<triple> の ENV に閉じており、ここでは環境変数を尊重して
無ければホスト向けの既定値を使う (CC/CXX/FC/OTOOL/CMAKE_TOOLCHAIN_FILE/OPENMP_*)。
リンク方針と wheel タグ (PLAT/RUNTIME_STATIC/...) は「環境の事実」ではなく TARGET から
一意に決まる方針なので下の POLICY 表に持ち、同じく環境変数で上書きできる。
"""

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"

# 段の依存。旧 makefile の .PHONY 依存から移設した唯一の真実。
# moab → hdf5 は HDF5_ROOT=$(PREFIX) を読むため (旧 makefile は `moab: src` で、
# `openmc-exe: hdf5 dagmc` の並び順のおかげで hdf5 が先に建っていた。ここで明示する)。
DEPS = {
    "src": [],
    "hdf5": ["src"],
    "moab": ["hdf5"],
    "dagmc": ["moab"],
    "njoy": ["src"],
    "openmc-exe": ["hdf5", "dagmc"],
    "openmc-lib": ["hdf5", "dagmc"],
    "wheel": ["openmc-exe", "openmc-lib", "njoy"],
}

# 自己完結の許可リスト。ここに載らない動的依存が1つでも残っていたら失敗させる。
_LINUX = r"linux-vdso|libc\.|libm\.|libpthread|libdl|librt|ld-linux"
_WINDLL = r"KERNEL32|SHELL32|SHLWAPI|api-ms-win-crt|ntdll|msvcrt"
ALLOW = {
    # glibc は manylinux_2_28 の前提なので動的のまま。libgomp は .so だけ動的に残り
    # (gcc-toolset の libgomp.a は非 PIC で .so に畳めない)、auditwheel repair が同梱する。
    ("linux", "lib"): _LINUX + r"|libgomp",
    ("linux", "exe"): _LINUX,
    # libmvec は glibc 2.22+ 同梱のベクトル数学ライブラリ (gfortran の自動ベクトル化が参照)
    ("linux", "njoy"): _LINUX + r"|libmvec",
    # 許すのは自分自身の install name と /usr/lib のシステムライブラリ (libSystem / libc++。
    # 全 macOS に存在) のみ。/opt/... や @rpath が残っていたら自己完結が壊れている。
    ("darwin", "lib"): r"libopenmc|/usr/lib/",
    ("darwin", "exe"): r"/usr/lib/",
    ("darwin", "njoy"): r"/usr/lib/",
    # SHLWAPI は HDF5 が Win32 API 経由で使う、全 Windows に存在する DLL
    ("windows", "lib"): _WINDLL,
    ("windows", "exe"): _WINDLL,
    ("windows", "njoy"): _WINDLL,
}


class Ctx:
    """TARGET から導出される全ての値。環境変数があればそちらを優先する。"""

    def __init__(self, target, jobs=8, dry_run=False):
        self.target = target
        self.arch = target.split("-")[0]
        self.jobs = jobs
        self.dry = dry_run
        self.os = (
            "windows" if "windows" in target
            else "darwin" if "apple" in target
            else "linux"
        )
        self.build = ROOT / "build" / target
        self.prefix = ROOT / "prefix" / target
        self.out = ROOT / "out" / target

        # ---- 環境の事実 (docker/Dockerfile_<triple> の ENV が注入する) ----
        # GNU Make の組み込みデフォルト (cc / f77) を避ける必要は python には無いので素直に読む。
        self.cc = os.environ.get("CC", "gcc")
        self.cxx = os.environ.get("CXX", "g++")
        self.fc = os.environ.get("FC", "gfortran")
        # darwin cross では docker ENV が cctools の <triple>-otool を指す
        self.otool = os.environ.get("OTOOL", "otool")

        # ---- 方針 (POLICY): TARGET から一意に決まる。環境変数で上書き可 ----
        # 旧 makefile の `?=` と同じ意味論。cmake 引数のリストを環境で上書きする場合は
        # シェル同様の分かち書きで渡す (例: HDF5_STATIC_ARG="-DHDF5_USE_STATIC_LIBRARIES=ON")。
        for k, v in POLICY[self.os](self).items():
            override = os.environ.get(k.upper())
            if override is not None:
                v = shlex.split(override) if isinstance(v, list) else override
            setattr(self, k, v)

        self.exe = self.out / f"openmc{self.exe_ext}"
        self.njoy_exe = self.out / f"njoy{self.exe_ext}"
        # 上流 CMake の POST_BUILD がソースツリーに落とす場所 (同 OS の 2 arch で同名衝突する)
        self.shlib = SRC / "openmc" / "openmc" / "lib" / f"libopenmc.{self.soext}"
        # per-target の退避先。wheel (hatch_build.py の force_include) はこちらを拾う
        self.shlib_out = self.out / f"libopenmc.{self.soext}"

    # ---- 実行ヘルパ ----
    def run(self, cmd, **kw):
        """外部コマンドを実行する。stdout は stderr に寄せる (stdout は wheel パス専用)。"""
        cmd = [str(x) for x in cmd]
        print("+ " + " ".join(cmd), file=sys.stderr, flush=True)
        if self.dry:
            return
        subprocess.run(cmd, check=True, stdout=sys.stderr, **kw)

    def capture(self, cmd, default=""):
        """値の問い合わせ。dry-run でも実行するが、失敗しても止めない (既定値で続ける)。"""
        try:
            return subprocess.run(
                [str(x) for x in cmd], check=True, capture_output=True, text=True
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return default

    def cmake(self, name, source, args, build_target=None, install=True):
        """configure → build -j → install の定型。6段のうち5段がこれで足りる。"""
        bdir = self.build / name
        self.run(["cmake", "-S", pp(source), "-B", pp(bdir)] + [str(a) for a in args])
        cmd = ["cmake", "--build", pp(bdir), "-j", self.jobs]
        if build_target:
            cmd += ["--target", build_target]
        self.run(cmd)
        if install:
            self.run(["cmake", "--install", pp(bdir)])

    # ---- 遅延評価する値 (ホストに gcc が無くても import できるように) ----
    @property
    def python3(self):
        """NJOY の CMake は configure 時に Python3 を要求する。ホストの python は
        Microsoft Store のスタブなので uv 管理のインタプリタを名指しする
        (manylinux コンテナにも uv が入っているので全 OS で同じ書き方が通る)。"""
        return pp(self.capture(["uv", "python", "find"], "python3"))

    @property
    def openmp_lib(self):
        """CMake の FindOpenMP は OpenMP ランタイムを「インポートライブラリの絶対パス」
        (.../libgomp.dll.a) として渡してくる。絶対パス指定は -static では覆せないので、
        そのままだと libgomp-1.dll (Linux では libgomp.so.1) への動的リンクが残り
        スタンドアローン性が壊れる。静的版を名指しして上書きする。
        ライブラリ名は GCC 系が gomp、clang 系 (darwin cross) が omp — docker ENV が
        OPENMP_LIB_NAME=omp / OPENMP_LIB=/opt/omp/lib/libomp.a を注入する。"""
        v = os.environ.get("OPENMP_LIB")
        if v:
            return v
        return self.capture([self.cxx, f"-print-file-name=lib{self.openmp_lib_name}.a"])

    @property
    def openmp_lib_name(self):
        return os.environ.get("OPENMP_LIB_NAME", "gomp")

    @property
    def openmp_static(self):
        args = [
            f"-DOpenMP_CXX_LIB_NAMES={self.openmp_lib_name}",
            f"-DOpenMP_C_LIB_NAMES={self.openmp_lib_name}",
            f"-DOpenMP_{self.openmp_lib_name}_LIBRARY={self.openmp_lib}",
        ]
        # FindOpenMP は OpenMP_<lang>_FLAGS と _LIB_NAMES の両方が事前設定のときだけ
        # try_compile 検出をスキップする。上は LIB_NAMES しか渡さないので検出が走り、
        # osxcross の aarch64-apple-darwin では検出が失敗して configure ごと落ちる
        # (CI run 29983656072 で実測。x86_64 は偶然通る)。darwin の docker ENV が
        # OPENMP_FLAGS=-fopenmp を注入して両方を揃え、検出を丸ごとバイパスする。
        # 未定義の環境 (linux / windows) は従来通り検出に任せる。
        flags = os.environ.get("OPENMP_FLAGS")
        if flags:
            args += [f"-DOpenMP_C_FLAGS={flags}", f"-DOpenMP_CXX_FLAGS={flags}"]
        return args

    @property
    def cmake_common(self):
        # -DCMAKE_POSITION_INDEPENDENT_CODE=ON: hdf5/moab/dagmc の静的 archive は Linux で
        # libopenmc.so に畳まれるので PIC が必須。Windows (PE) では無害な no-op。
        return [
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DCMAKE_C_COMPILER={self.cc}",
            f"-DCMAKE_CXX_COMPILER={self.cxx}",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
            f"-DCMAKE_INSTALL_PREFIX={pp(self.prefix)}",
        ]

    @property
    def openmc_cmake(self):
        args = self.cmake_common + [
            f"-DHDF5_ROOT={pp(self.prefix)}",
            "-DHDF5_PREFER_PARALLEL=FALSE",
            "-DOPENMC_USE_OPENMP=ON",
            "-DOPENMC_BUILD_TESTS=OFF",
            "-DOPENMC_FORCE_VENDORED_LIBS=ON",
            "-DOPENMC_USE_MPI=OFF",
            "-DOPENMC_USE_LIBMESH=OFF",
            "-DOPENMC_USE_DAGMC=ON",
            "-DOPENMC_USE_UWUW=OFF",
            f"-DCMAKE_PREFIX_PATH={pp(self.prefix)}",
        ]
        return args + self.hdf5_static_arg + self.link_tail


def pp(path):
    """cmake や uv に渡すパスは常にスラッシュ区切りにする (Windows ホストの check 経路対策)。"""
    return Path(path).as_posix()


# ============================ POLICY (OS ごとの方針) ============================
# 旧 makefile の ifeq ブロック (OS ごとのリンクフラグと wheel プラットフォームタグ) を
# そのまま移設したもの。値は環境変数 (大文字のキー名) で上書きできる。


def _windows(c):
    return dict(
        soext="dll",
        exe_ext=".exe",
        plat="win_amd64",
        plat_build="win_amd64",
        # -static 一発で libstdc++/libgcc/libwinpthread まで全部畳める (exe で実測済み)
        runtime_static="-static",
        # MinGW では .a が import-lib の拡張子でもあるため HDF5_USE_STATIC_LIBRARIES は
        # 渡してはいけない: 指定なしで通っており、指定するとリンク順が変わって MOAB の
        # deprecated API (H5Aopen_name) が未解決になる (実測)。
        hdf5_static_arg=[],
        link_tail=[],
        # -static 一発で libgfortran/quadmath/winpthread まで畳める (openmc.exe と同じ)
        njoy_static="-static",
    )


def _darwin(c):
    return dict(
        soext="dylib",
        exe_ext="",
        plat=f"macosx_11_0_{c.arch.replace('aarch64', 'arm64')}",
        plat_build=f"macosx_11_0_{c.arch.replace('aarch64', 'arm64')}",
        # システム libc++/libSystem は全 macOS にあるのでランタイムの静的化は不要。
        # deployment target 11.0 は docker ENV の MACOSX_DEPLOYMENT_TARGET と対で管理する。
        runtime_static="",
        # FindHDF5 が既定で共有ライブラリを探すのは Linux と同じ → 静的のみインストールには必須
        hdf5_static_arg=["-DHDF5_USE_STATIC_LIBRARIES=ON"],
        # ld64 は単一パスの ld ではないのでリンク順問題 (linux の link_tail) は構造的に起きない
        link_tail=[],
        # flang の Fortran ランタイムの畳み方は docker ENV (NJOY_STATIC) 側で調整する
        njoy_static="",
    )


def _linux(c):
    return dict(
        soext="so",
        exe_ext="",
        # ビルドを quay.io/pypa/manylinux_2_28 で行い、glibc 以外への動的依存を
        # 排除する断言をかけることが manylinux_2_28 タグの根拠。
        plat=f"manylinux_2_28_{c.arch}",
        # wheel はまず素の linux_<arch> タグで作り、auditwheel repair が retag する
        plat_build=f"linux_{c.arch}",
        # glibc は manylinux の前提なので動的のまま、gcc ランタイムだけ静的にする
        runtime_static="-static-libgcc -static-libstdc++",
        # Linux の FindHDF5 は既定で .so を探すため、静的のみのインストールだと
        # HDF5_LIBRARIES が見つからず configure が落ちる (実測、moab で発生)。
        hdf5_static_arg=["-DHDF5_USE_STATIC_LIBRARIES=ON"],
        # CMake が組むリンク行は ...libhdf5.a ... libMOAB.a の順になり、単一パスの ld では
        # MOAB の mhdf が使う deprecated API (H5Aopen_name / H5Fis_hdf5) だけが未解決になる
        # (他の H5 シンボルは libopenmc が先に引き込んだオブジェクトで偶然足りる。実測)。
        # CMAKE_CXX_STANDARD_LIBRARIES は全 exe/共有 lib のリンク行末尾に付くので HDF5 を
        # 再掲して閉じる (Linux の既定値は空なので上書きしても何も失わない)。
        link_tail=[
            "-DCMAKE_CXX_STANDARD_LIBRARIES="
            f"{pp(c.prefix)}/lib/libhdf5_hl.a {pp(c.prefix)}/lib/libhdf5.a"
        ],
        # gcc-toolset-14 に libgfortran.a / libquadmath.a がある (実測 probe)。
        # -static-libquadmath は GCC>=13。glibc は動的のまま = manylinux の前提どおり
        njoy_static="-static-libgfortran -static-libquadmath -static-libgcc",
    )


POLICY = {"windows": _windows, "darwin": _darwin, "linux": _linux}


# ================================== 段 ==================================


def stage_src(c):
    """上流は全部 submodule で取得する。openmc は full clone (タグが入り CMake の
    GetVersionFromGit がそのまま動く。shallow だと openmc --version が 0.0.0 になる)。
    moab は tarball 不可 — 配布 tarball は autotools の `make dist` 産物で、CMake 用の
    config/{logging,dist,distcheck}.cmake が EXTRA_DIST から漏れており configure が落ちる。

    パッチは src/*.patch を全部当てる。当て先はファイル名の最初の '-' より前のトークン
    (openmc-static-lib.patch → src/openmc)。適用済みなら黙って飛ばす
    (-R --dry-run が通る = すでに当たっている、という判定)。"""
    c.run(["git", "submodule", "update", "--init", "--recursive"])
    for patch in sorted(SRC.glob("*.patch")):
        name = patch.stem
        dest = SRC / name.split("-")[0]
        applied = subprocess.run(
            ["patch", "-p1", "-d", pp(dest), "-R", "--dry-run", "-s", "-f"],
            stdin=patch.open("rb"),
            capture_output=True,
        ).returncode == 0
        if applied:
            print(f"{name}: already applied", file=sys.stderr)
            continue
        print(f"+ patch -p1 -d {pp(dest)} < {patch.name}", file=sys.stderr, flush=True)
        if not c.dry:
            subprocess.run(
                ["patch", "-p1", "-d", pp(dest)],
                stdin=patch.open("rb"), check=True, stdout=sys.stderr,
            )
        print(f"{name}: applied", file=sys.stderr)


def stage_hdf5(c):
    """静的 (BUILD_SHARED_LIBS=OFF) にして Windows の DLL シンボル export 問題を丸ごと回避する。
    OpenMC は C API と HL のみ使うので C++/Fortran/tools は全部切る。zlib は HDF5 2.x の既定通り OFF。"""
    if not shutil.which("cmake") and not c.dry:
        sys.exit("cmake not found in PATH; install it and retry")
    c.cmake("hdf5", SRC / "hdf5", c.cmake_common + [
        "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_STATIC_LIBS=ON",
        "-DBUILD_TESTING=OFF", "-DHDF5_BUILD_EXAMPLES=OFF", "-DHDF5_BUILD_TOOLS=OFF",
        "-DHDF5_BUILD_HL_LIB=ON", "-DHDF5_BUILD_CPP_LIB=OFF", "-DHDF5_BUILD_FORTRAN=OFF",
        "-DHDF5_ENABLE_THREADSAFE=OFF", "-DHDF5_ENABLE_SZIP_SUPPORT=OFF",
        "-DHDF5_ENABLE_ZLIB_SUPPORT=OFF",
    ])


def stage_moab(c):
    """.h5m は MOAB のファイル形式そのもので、DAGMC は MOAB の上の薄い層。静的
    (BUILD_SHARED_LIBS=OFF) にするのが肝: 共有だと MSVC 構文のフラグ (/DMOAB_DLL) が
    GCC に渡り落ちる。既定 ON で落ちるもの (BLASLAPACK/FORTRAN/TESTING) は明示的に切る。"""
    c.cmake("moab", SRC / "moab", c.cmake_common + [
        "-DBUILD_SHARED_LIBS=OFF",
        "-DENABLE_HDF5=ON", f"-DHDF5_ROOT={pp(c.prefix)}",
    ] + c.hdf5_static_arg + [
        "-DENABLE_BLASLAPACK=OFF", "-DENABLE_FORTRAN=OFF", "-DENABLE_TESTING=OFF",
        "-DENABLE_PYMOAB=OFF", "-DENABLE_NETCDF=OFF", "-DENABLE_MPI=OFF",
        "-DENABLE_METIS=OFF", "-DENABLE_ZOLTAN=OFF", "-DENABLE_PARMETIS=OFF",
        "-DENABLE_TEMPESTREMAP=OFF", "-DENABLE_CGNS=OFF", "-DENABLE_CPM=OFF",
    ])


def stage_dagmc(c):
    """タグ付きリリースを使う。UWUW と TALLY は既定 ON だが OpenMC は使わない (UWUW は PyNE を
    引き込むので特に切る)。DAGMCConfig.cmake は install prefix を焼き込むので最終位置に直接入れる。"""
    c.cmake("dagmc", SRC / "dagmc", c.cmake_common + [
        f"-DMOAB_DIR={pp(c.prefix)}", f"-DHDF5_ROOT={pp(c.prefix)}",
    ] + c.hdf5_static_arg + [
        "-DBUILD_STATIC_LIBS=ON", "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_UWUW=OFF", "-DBUILD_TALLY=OFF",
        "-DBUILD_BUILD_OBB=OFF", "-DBUILD_MAKE_WATERTIGHT=OFF", "-DBUILD_OVERLAP_CHECK=OFF",
        "-DBUILD_TESTS=OFF", "-DBUILD_CI_TESTS=OFF",
        "-DBUILD_EXE=OFF", "-DBUILD_STATIC_EXE=OFF", "-DBUILD_RPATH=OFF",
        "-DDOUBLE_DOWN=OFF", "-DPULL_INSTALL_MOAB=OFF",
    ])


def stage_njoy(c):
    """openmc.data.IncidentNeutron.from_njoy() が PATH 上の literal 'njoy' を Popen する
    (openmc/data/njoy.py:358) ので、openmc.exe と同じ .data/scripts 同梱で成立する。
    tests/ は ctest 登録のみでビルド産物なし → njoy_executable ターゲットだけビルドすれば
    テスト無効化スイッチは不要。install ターゲットが無いので build dir から自前でコピー。
    cmake_common は使わない (Fortran 専用で C/C++・install prefix・PIC のどれも不要。
    クロスは環境変数 CMAKE_TOOLCHAIN_FILE が全 cmake 呼び出しに効くのでここも成立する)。
    Windows ビルドは前例なし (上流 CI は ubuntu のみ、conda-forge は skip: win)、darwin は
    flang クロス (docker ENV の FC) — 壊れたら src/njoy-*.patch に最小パッチを足す。"""
    c.cmake("njoy", SRC / "njoy", [
        "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_Fortran_COMPILER={c.fc}",
        f"-DPython3_EXECUTABLE={c.python3}",
        f"-DCMAKE_EXE_LINKER_FLAGS={c.njoy_static}",
    ], build_target="njoy_executable", install=False)
    copy(c, c.build / "njoy" / f"njoy{c.exe_ext}", c.njoy_exe)


def stage_openmc_exe(c):
    """OPENMC_STATIC_LIB=ON (src/openmc-static-lib.patch) で libopenmc を静的にし、
    exe をランタイムごと自己完結にする。DLL と exe を同じビルドでリンクすると MinGW の
    全シンボル自動エクスポートで _Unwind_Resume が exe 側静的 libgcc_eh.a と multiple
    definition になる (sandbox-openmc-source で実測) ので、exe と共有ライブラリは
    ビルドディレクトリごと分ける。コンパイル2倍は構造的安全のコスト。"""
    c.cmake("openmc-exe", SRC / "openmc", c.openmc_cmake + c.openmp_static + [
        "-DOPENMC_STATIC_LIB=ON",
        f"-DCMAKE_EXE_LINKER_FLAGS={c.runtime_static}",
    ])
    for f in sorted((c.prefix / "bin").glob("openmc*")):
        copy(c, f, c.out / f.name)


def stage_openmc_lib(c):
    """SHARED でも runtime_static でランタイムを畳み、CDLL が絶対パスだけでロードできる
    自己完結な DLL/so/dylib にする。ビルドは libopenmc ターゲットのみ (exe をリンクしないので
    上記 multiple definition が構造的に起きない)。出来上がりは上流 CMakeLists の POST_BUILD が
    ソースツリー openmc/lib/ にコピーするが、そこは全 TARGET 共有で同 OS の 2 arch が
    同名衝突するため、直後に per-target の out/ へ退避する。wheel はそちらを拾う。"""
    # gcc-toolset (linux) の libgomp.a は非 PIC (TLS 再配置 R_X86_64_TPOFF32) で .so に
    # 畳めない (実測) ため、Linux の共有 lib は動的 libgomp のままにして auditwheel repair に
    # 同梱させる。windows / darwin のオブジェクトは常に PIC なので畳める。
    openmp = [] if c.os == "linux" else c.openmp_static
    # --exclude-libs,ALL: 静的 archive 由来のシンボル (H5* / MOAB / pugixml / fmt) を .so から
    # エクスポートしない。しないと同一プロセスの h5py が持つ別ビルドの HDF5 と ELF のシンボル
    # 介入 (interposition) が起き、openmc_init が segfault する (実測: h5py を import しない
    # プロセスでは同じ .so が正常動作)。Windows の DLL と Mach-O の two-level namespace は
    # そもそも介入が構造的に無いので不要。
    ldflags = c.runtime_static + (" -Wl,--exclude-libs,ALL" if c.os == "linux" else "")
    c.cmake("openmc-lib", SRC / "openmc", c.openmc_cmake + openmp + [
        f"-DCMAKE_SHARED_LINKER_FLAGS={ldflags.strip()}",
    ], build_target="libopenmc", install=False)
    if not c.dry and not c.shlib.exists():
        sys.exit(f"POST_BUILD copy did not produce {c.shlib}")
    copy(c, c.shlib, c.shlib_out)


def stage_wheel(c):
    """タグは py3-none-<plat> (hatch_build.py が OPENMC_ANYWHERE_PLAT から組む)。python
    パッケージは pure Python なので CPython バージョン別の wheel は要らない。
    uv は manylinux イメージにも同梱されているので全 OS で同じコマンドが使える。"""
    env = dict(os.environ)
    env["OPENMC_ANYWHERE_PLAT"] = c.plat_build
    env["OPENMC_ANYWHERE_OUT"] = f"out/{c.target}"
    env["OPENMC_ANYWHERE_SOEXT"] = c.soext
    env["OPENMC_ANYWHERE_NJOY"] = pp(c.njoy_exe)
    c.run(["uv", "build", "--wheel", "--out-dir", "dist"], env=env)

    # 自己完結の断言。ここで落とすことが wheel のプラットフォームタグの根拠になる。
    if c.os in ("linux", "darwin"):
        assert_self_contained(c, c.shlib_out, "lib")
        assert_self_contained(c, c.exe, "exe")
        assert_self_contained(c, c.njoy_exe, "njoy")

    if c.os == "linux":
        # 素の linux_<arch> タグで作った wheel を auditwheel repair が libgomp.so.1 を
        # 同梱 (openmc_anywhere.libs/、RPATH 書き換え) して manylinux_2_28 に retag する。
        for w in sorted((ROOT / "dist").glob(f"openmc_anywhere-*-{c.plat_build}.whl")):
            c.run(["auditwheel", "repair", "--plat", c.plat, "-w", "dist", pp(w)])
            if not c.dry:
                w.unlink()
    print(wheel_path(c))


def stage_check(c):
    """wheel を venv に入れ、check.py の5経路 (exe / openmc.lib / model / DAGMC / njoy) を通す。
    PATH に venv の Scripts (bin) を前置するのが肝: python を直接叩くだけでは PATH に乗らず、
    上流 executor.py の literal 'openmc' 解決 (利用者が activate した状態の再現) が失敗する。
    核データは要らない (check.py がデータ不要の経路だけに絞ってある)。"""
    if c.os == "windows":
        # objdump の断言2つ: DLL の import がシステム DLL のみ (自己完結の証明) と、
        # openmc_init をエクスポート (ctypes が読める形の証明)。
        assert_self_contained(c, c.shlib_out, "lib")
        assert_self_contained(c, c.njoy_exe, "njoy")
        if not c.dry and "openmc_init" not in c.capture(["objdump", "-p", pp(c.shlib_out)]):
            sys.exit("openmc_init not exported")

    venv = ROOT / "venv-check"
    c.run(["uv", "venv", pp(venv), "--python", "3.12", "--allow-existing"])
    c.run(["uv", "pip", "install", "--python", pp(venv), "--reinstall", wheel_path(c)])

    bindir = venv / ("Scripts" if c.os == "windows" else "bin")
    rundir = c.build / "check-run"
    if not c.dry:
        shutil.rmtree(rundir, ignore_errors=True)
        rundir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PATH"] = str(bindir) + os.pathsep + env["PATH"]
    c.run(
        [bindir / ("python.exe" if c.os == "windows" else "python"), pp(ROOT / "check.py"),
         pp(SRC / "openmc/tests/regression_tests/dagmc/legacy/dagmc.h5m")],
        env=env, cwd=None if c.dry else rundir,
    )


STAGES = {
    "src": stage_src, "hdf5": stage_hdf5, "moab": stage_moab, "dagmc": stage_dagmc,
    "njoy": stage_njoy, "openmc-exe": stage_openmc_exe, "openmc-lib": stage_openmc_lib,
    "wheel": stage_wheel,
}


# ================================ ユーティリティ ================================


def copy(c, src, dst):
    print(f"+ cp {pp(src)} {pp(dst)}", file=sys.stderr, flush=True)
    if not c.dry:
        Path(dst).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def wheel_path(c):
    """完成 wheel のパス。dist/ に無ければ (dry-run 等) 想定名を返す。"""
    found = sorted((ROOT / "dist").glob(f"openmc_anywhere-*-py3-none-{c.plat}.whl"))
    return pp(found[-1]) if found else pp(ROOT / "dist" / f"openmc_anywhere-*-py3-none-{c.plat}.whl")


def dynamic_deps(c, binary):
    """バイナリの動的依存の一覧。OS ごとにコマンドと出力形式が違うのをここで吸収する。"""
    if c.os == "linux":
        out = c.capture(["ldd", pp(binary)])
        return [ln.split("=>")[0].strip() for ln in out.splitlines() if "=>" in ln]
    if c.os == "darwin":
        out = c.capture([c.otool, "-L", pp(binary)])
        return [ln.split()[0] for ln in out.splitlines()[1:] if "compatibility" in ln]
    out = c.capture(["objdump", "-p", pp(binary)])
    return [ln.split("DLL Name:")[1].strip() for ln in out.splitlines() if "DLL Name:" in ln]


def assert_self_contained(c, binary, what):
    """許可リストに載らない動的依存が残っていたら失敗させる (自己完結の証明)。"""
    deps = dynamic_deps(c, binary)
    print(f"== deps of {Path(binary).name} ==\n" + "\n".join("  " + d for d in deps),
          file=sys.stderr)
    allow = ALLOW[(c.os, what)]
    bad = [d for d in deps if not re.search(allow, d, re.IGNORECASE)]
    if bad and not c.dry:
        sys.exit(f"unexpected shared dependency in {Path(binary).name}: {bad}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("stage", choices=list(STAGES) + ["check", "path"])
    ap.add_argument("--target", required=True)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--dry-run", action="store_true", help="コマンドを表示するだけで実行しない")
    a = ap.parse_args()
    c = Ctx(a.target, a.jobs, a.dry_run)

    if a.stage == "path":
        print(wheel_path(c))
        return
    if a.stage == "check":
        stage_check(c)
        return

    done = set()

    def run_stage(name):
        if name in done:
            return
        done.add(name)
        for dep in DEPS[name]:
            run_stage(dep)
        print(f"===== {name} ({c.target}) =====", file=sys.stderr, flush=True)
        STAGES[name](c)

    run_stage(a.stage)


if __name__ == "__main__":
    main()
