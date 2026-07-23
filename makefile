# openmc-anywhere: OpenMC の PyPI 形式バイナリ wheel を作る。`uv add openmc-anywhere` だけで
# 公式 OpenMC のコードが Windows / Linux / macOS でそのまま動く (openmc 実行ファイル +
# libopenmc 共有ライブラリ + njoy 同梱、DAGMC 込み) ことをゴールにする。
#
#   make                 # (デフォルト) TARGET の wheel をビルドし、パスを stdout に印字
#   make <stage>         # 段だけ回す (src hdf5 moab dagmc njoy openmc-exe openmc-lib wheel)
#   make cross-<triple>  # docker/Dockerfile_<triple> の toolchain イメージ内で wheel をビルド
#                        #   (x86_64|aarch64)-unknown-linux-gnu / (x86_64|aarch64)-apple-darwin
#                        #   / x86_64-pc-windows-gnu
#   make check           # cross で作った wheel をホストの venv に入れて end-to-end 検証
#   make check-linux     # 素の python:3.12 コンテナで Linux wheel を検証 (可搬性の証明)
#   make clean           # build/ prefix/ out/ dist/ venv-check/ を削除
#
# この makefile はコマンドメニューに徹する (issue #9)。責務の分割は3層:
#   環境の事実 (コンパイラ・SDK・toolchain) → docker/Dockerfile_<triple> の ENV
#   段取り・リンク方針・自己完結の断言   → build.py
#   docker と gh の呼び出し              → ここ
# wheel は全 TARGET を docker クロスで作る (ホストのネイティブビルド経路は #9 で廃止)。

# Git Bash が docker/cmake の引数中のパス (-w /io, -v C:/...:/io) を MSYS パスへ勝手に
# 変換するのを防ぐ (Windows ホストから make cross-* を叩くときに効く。Linux では無害)。
export MSYS_NO_PATHCONV=1

JOBS ?= 8
# WITH_NJOY=0 で njoy 無し wheel になる (darwin の flang クロスが通らない場合の逃げ道)
export WITH_NJOY ?= 1

# ---- ビルドターゲット triple。ホストから自動判別し、cross-% / CI / docker が上書きする ----
ifeq ($(OS),Windows_NT)
  TARGET ?= x86_64-pc-windows-gnu
else ifeq ($(shell uname -s),Darwin)
  TARGET ?= $(subst arm64,aarch64,$(shell uname -m))-apple-darwin
else
  TARGET ?= $(shell uname -m)-unknown-linux-gnu
endif

# pyproject.toml の version と単一ソース化 (submodule を進めたら pyproject 側を上げる)
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)

# uv は全 docker イメージと Windows ホストに入っている。--no-project が必須 —
# 付けないと uv が pyproject.toml の dependencies (numpy/h5py/...) を同期しに行く。
B := uv run --no-project build.py --target $(TARGET) --jobs $(JOBS)

# 検証用の断面積データ置き場。wheel には焼き込まない (利用者が OPENMC_CROSS_SECTIONS で渡す)。
XSDIR ?= C:/Users/smith/mhd-tbr-stell/sandbox-openmc/data

STAGES := src hdf5 moab dagmc njoy openmc-exe openmc-lib wheel
.PHONY: default check check-linux release clean $(STAGES)

# デフォルト: wheel をビルドし、そのパスだけを stdout に出す (build.py がそう振る舞う)。
# 段の依存 (hdf5→src, dagmc→moab, wheel→exe+lib+njoy ...) は build.py が持つ。
default: wheel

$(STAGES):
	@$(B) $@

# wheel には依存させない: 検証対象は cross で作った wheel (ホストではビルドしない)。
#   make cross-x86_64-pc-windows-gnu && make check
check:
	@$(B) check --xsdir $(XSDIR)

# ================= クロスビルド (Docker) =================
# docker/Dockerfile_<triple> の toolchain イメージ (project 非依存、ソースは実行時
# bind-mount) を組み、repo をマウントして同じ makefile を TARGET=<triple> で回す
# (github.com/lzpel/cadrum の方式)。
# safe.directory: マウントした repo の所有者が container の root と食い違うため。
cross-%:
	docker build -f docker/Dockerfile_$* -t cross-$* . 1>&2
	docker run --rm -v $(CURDIR):/io -w /io cross-$* \
	  bash -c "git config --global --add safe.directory '*' && make wheel TARGET=$* JOBS=$(JOBS)" 1>&2
	@uv run --no-project build.py path --target $*

# 検証はビルドイメージではなく素の python:3.12 で行う (可搬性の証明)。データは読み取りで
# 足りるので :ro。check.py の生成物はコンテナ内 /tmp に落ちて廃棄される。
# python:3.12 はホストの arch で解決されるので、arm ホストなら aarch64 wheel の検証になる。
check-linux:
	docker run --rm -v $(CURDIR):/io:ro -v $(XSDIR):/data:ro \
	  -e OPENMC_CROSS_SECTIONS=/data/lib/cross_sections.xml python:3.12 \
	  bash -c "pip install -q /io/dist/openmc_anywhere-*-manylinux*.whl \
	    && mkdir /tmp/run && cd /tmp/run \
	    && python /io/check.py /io/src/openmc/tests/regression_tests/dagmc/legacy/dagmc.h5m \
	         --endf /data/endf/Li6.endf"

# ================= 公開 =================
# wheel は git に入れず Release asset として配る。CI (.github/workflows/prebuilt.yml) が
# prebuilt ブランチへの push で全 TARGET をビルドして Release を自動作成するのが正規経路。
# この手動 release は逃げ道 (タグ既存なら gh が落ちる = 意図通り)。
release:
	gh release create v$(VERSION) --title v$(VERSION) \
	  --notes "openmc + libopenmc + njoy bundled wheels" \
	  dist/openmc_anywhere-$(VERSION)-py3-none-*.whl 1>&2

clean:
	rm -rf $(CURDIR)/build $(CURDIR)/prefix $(CURDIR)/out dist venv-check
