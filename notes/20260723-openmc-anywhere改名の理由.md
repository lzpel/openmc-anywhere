# openmc-anywhere 改名の理由

The old distribution name `openmc-pypi` named the delivery channel instead of the thing delivered, and a package literally called "openmc-pypi" reads as *the* official PyPI channel for OpenMC — an impression this project has no right to give.
`openmc-anywhere` states the actual value proposition in one word: a self-contained wheel that runs on Windows, Linux and macOS across x86_64 and aarch64, with no conda, no Docker and no source build, because the openmc executable, libopenmc and njoy are all statically linked and shipped inside it.
The word also moves expectations in the right direction — it sounds like somebody's convenience packaging rather than an upstream artifact, which is exactly what an unofficial rebuild of OpenMC should sound like.
Nothing has been published to PyPI yet, so the rename costs one search-and-replace over ten files today instead of a permanent compatibility shim later, and it removes a future collision if upstream ever claims the `openmc` name on PyPI itself.
The price is the index URL: `https://lzpel.github.io/openmc-pypi/wheel/` dies without a redirect (GitHub forwards repository URLs but not Pages), and the wheels already attached to release v0.15.3.post214 keep their old file name, so the index generator now selects assets by the `openmc_anywhere-` prefix.

---

旧配布名 `openmc-pypi` は「届ける中身」ではなく「届ける経路」を名前にしており、しかも openmc-pypi という名前は OpenMC 公式の PyPI 配布そのものに読める — 本プロジェクトが与えてよい印象ではない。
`openmc-anywhere` は価値提案を1単語で言い切る: conda も Docker も自前ビルドも要らず、Windows / Linux / macOS の x86_64・aarch64 でそのまま動く自己完結 wheel であること。openmc 実行ファイル・libopenmc・njoy を静的リンクして同梱しているからそう名乗れる。
この語は期待値を正しい向きに動かしもする。上流の成果物ではなく誰かの便宜的パッケージングに聞こえるが、OpenMC の非公式リビルドはまさにそう聞こえるべきである。
まだ PyPI に公開していないので、改名コストは今日10ファイルの一括置換だけで済み、後年まで互換用の別名パッケージを抱える羽目にならない。将来上流が PyPI の `openmc` を取った場合の紛らわしさも先に消える。
代償は index URL で、`https://lzpel.github.io/openmc-pypi/wheel/` はリダイレクトされずに失効する (GitHub はリポジトリ URL を転送するが Pages は転送しない)。既に Release v0.15.3.post214 にぶら下がっている wheel も旧名のままなので、index 生成側は `openmc_anywhere-` プレフィックスで asset を選ぶようにした。
