export MSYS_NO_PATHCONV=1

# ---- ビルドターゲット triple。ホストから自動判別し、cross-% / CI / docker が上書きする ----
TARGET ?= $(shell uname -m | sed 's/arm64/aarch64/')-$(shell uname -s | sed -e 's/Darwin/apple-darwin/' -e 's/Linux/unknown-linux-gnu/' -e 's/^\(MINGW\|MSYS\|CYGWIN\).*/pc-windows-gnu/')

STAGES := src hdf5 moab dagmc njoy openmc-exe openmc-lib wheel

default: wheel ## default: wheel 段の依存 (hdf5→src, dagmc→moab, wheel→exe+lib+njoy ...) は build.py が持つ

$(STAGES): ## 各ステージのビルド
	uv run --no-project build.py --target $(TARGET) $@

cross-%: ## docker/Dockerfile_<triple> の toolchain イメージ内で wheel をビルド
	docker build -f docker/Dockerfile_$* -t cross-$* .
	docker run --rm -v $(CURDIR):/io -w /io cross-$* bash -c "git config --global --add safe.directory '*' && make wheel TARGET=$*"
	uv run --no-project build.py path --target $*

check: ## ローカル検証 (核データ不要) e.g. make cross-x86_64-pc-windows-gnu && make check
	uv run --no-project build.py --target $(TARGET) check

clean: ## ビルド成果物を削除する
	rm -rf $(CURDIR)/build $(CURDIR)/prefix $(CURDIR)/out dist venv-check

help: ## ヘルプを表示する
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
