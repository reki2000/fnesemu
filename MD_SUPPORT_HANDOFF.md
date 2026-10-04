# md support: 再開メモ

## 作業場所・制約

- worktree: `/tmp/fnesemu-md-cdrom`
- branch: `feature/md-cdrom`
- `origin/fix/md-core-bugs` は取り込み済み。
- CD 部分の表記は `md cdrom support`。ユーザー指定の商標名をコード・ドキュメント・コミットに書かない。
- 32x は `md 32x`。配置は `lib/core/md/32x/sh2/sh2.dart` など。`expansion/` ディレクトリを作らない。
- 通常 MD の速度を守る。通常カートリッジではアダプタも専用バスも生成しない。
- SDK: `/home/reki/.local/share/mise/installs/flutter/3.47.5-stable/bin`
- シェルは `login:false` で workdir を指定する。Git の更新と Flutter の SDK キャッシュ更新は sandbox の escalation が必要。

## 完了した内容

CD: BIOS/sub 68000、PRG/Word RAM、BRAM、CDD/CDC、PCM/CD-DA、stamp graphics、ディスクローダーとデバッガ統合。
32x: SH-2 整数命令・遅延分岐・外部 IRQ・sleep、dual CPU scheduler、共有 SDRAM、ROM 窓、通信ポート、DREQ FIFO、bitmap VDP、PWM、デバッガ。
32x の通常 MD バスへのフックは除去し、利用時だけ `32x/bus_m68.dart` の専用バスを装着する。切り替え時は RAM/Pad/ROM と CPU/Z80/VDP の参照を維持する。
ADEN clear/reset held では CPU と周辺機器を止め、再開時に停止期間の計算を行わない。opacity buffer と追加 CPU 実行フラグ map は必要時に割り当てる。
`.32x` は GUI の ROM/ZIP ローダーと CoreFactory から MD 32x コアに渡る。ROM ヘッダに 32X 表記がなくても拡張子でアダプタを選べることを統合テストで確認した。

手元の実 32X ROM は 4 MiB の `.32x` を含み、manufacturer 32X ヘッダを持つ。ZIP 内の ROM を `/tmp/md32x-cart.32x` に展開して確認。実ブート ROM (main / master / slave) は順に 256 / 2048 / 1024 bytes。作業用に `/tmp/md32x-main-boot.bin`、`/tmp/md32x-master-boot.bin`、`/tmp/md32x-slave-boot.bin` に展開した。ROM と BIOS はリポジトリに入れていない。

最初の実 ROM 起動は slave SH-2 が `0xc00005f0` の `ffff` で停止した。これは SH-2 のキャッシュデータ領域を通常の uncached alias として写像していたため。CPU ごとに独立した 4 KiB のデータ領域を追加し、32-bit 読み書き・CPU 間分離・リセットを単体テストで検証した。修正後は 600 frames で停止せず、120 frames で起動ロゴ、600 frames でタイトル画面を画像で確認。700 frames で Start を押すとモード選択画面へ、930 frames でもう一度押すとキャラクター選択画面へ進んだ。さらに 1250 frames で Start を押すと、1380 frames に master SH-2 が `0x060054ac` の `0x0fff` 命令で停止した。周辺は `CLRMAC` と `MAC.L` 2 回を含む正常な命令列であり、未実装だった `MAC.L` を追加した。次に 1383 frames で master SH-2 が `0xc00000bc` の `0x4edf` 命令で停止。周辺は `MAC.W` 3 回を含む正常な命令列であり、`MAC.W` も追加した。両命令の符号付き積和、ポストインクリメント、S ビットによる飽和を単体テストで検証した。その後 1800 frames まで停止せず、対戦の HUD と背景を確認した。ただしキャラクターは表示されず、描画は未完成。1500 frames の表示レジスタは mode=1、control=0x8003、両バンクとも非ゼロ byte は先頭のライン表 240 個のみで、pixel 本体が書かれていない。画面合成より前のデータ生成・転送経路を調べる必要がある。ログ `/tmp/md32x-cart-boot2.log`、`/tmp/md32x-cart-stop{,2}.log`、`/tmp/md32x-cart-mac2.log`、`/tmp/md32x-video.log`、画像 `/tmp/md32x-cart-{120,300,600}.png` と `/tmp/md32x-cart-play-{750,900,1000,1200,1500,1800}.png`。

実ディスク確認で修正した点:

- 同じ IMG の INDEX 00/01 間ギャップで音声の位置とディスク長がずれる CUE の不具合。
- CDD リセット応答をゼロ + checksum F にする。
- CDD Stop/Close 応答を tick で上書きせず、次のコマンドまで保持する。
- 再生位置の負の lead-in を許可し、LBA 0 の前ではデコーダにデータを渡さない。
- `lib/tools/md_cdrom.dart` に Start 自動入力と PNG/状態ダンプ出力を追加。

## 実 BIOS / 実ディスク確認結果

ユーザー提供 BIOS は `/tmp/md-cdrom-bios.bin` から参照可能。この symlink のリンク先は元のユーザー指定ファイル。BIOS・ゲームはリポジトリに入れていない。
メディアは手元の実ディスクイメージ (cue + img)。
BIOS は 128 KiB、IMG は 562892400 bytes = 239325 raw sectors、8 tracks。

修正前は黒画面・サブ BIOS 初期化の繰り返し。修正後は起動画面と Start 応答、TOC 取得、データ読み込みを確認。
1800 frames、Start=600..614 で CPU 未実装命令による停止なし。
ただし Start 後は「しばらくお待ち下さい」のままで、実ディスク のゲーム画面には到達しない。
最終 CDD=1 / LBA=2120、main PC=0x10ec、sub PC=0x615a。
主・サブの通信は継続しているので、この PC の一回のサンプルだけでデッドロックと判断しない。

再開後に専用 32x バスへの整理を含む現行版で 1800 frames を再実行し、同じ待機状態を確認した。
CDC のレジスタを追うと、デコーダ割り込み処理は毎セクタ実行される一方、データ転送開始レジスタへの書き込み、host 読み出し、DMA は 900 frames まで一度も発生しない。
CRC 状態・MODE/FORM 状態・STAT3 読み出し・IFSTAT の転送ビットと DTACK を修正し、単体テストを追加した。この修正のみの 1800-frame 実ディスク再実行ではゲーム画面には進まない。
実行ログは `/tmp/md-cdrom-recheck.log`、`/tmp/md-cdrom-cdcfix.log`、CDC アクセスのトレースは `/tmp/md-cdc-watch-fix.log`。

主 CPU が IRQ2 を送るタイミングとサブ CPU の待機が重なる点も調査した。複数 IRQ の全レベル保留、および CD 側だけの IRQ2 保留をそれぞれ試したが、実ディスクではゲーム起動につながらず表示・ドライブ動作が変わったため採用していない。一般の MD の IRQ 経路は元のまま。再調査時は `/tmp/md-comm-watch3.log` と `/tmp/md-cdrom-{irqfix,latch-long}.log` を参照できる。

成果物:

- `/tmp/md-cdrom-check.log`
- `/tmp/md-cdrom-check/frame-{300,600,900,1200,1500,1800}.{png,txt}`
- 一時解析用 `/tmp/md_cd_probe.dart`、`/tmp/md_cd_trace.dart` と `/tmp/md-cd-*.log`。これらは本番コードではなく、試行途中の出力も含む。

再現コマンド（worktree で実行）:

```sh
SDK=/home/reki/.local/share/mise/installs/flutter/3.47.5-stable/bin
"$SDK/cache/dart-sdk/bin/dart" --packages=.dart_tool/package_config.json \
  lib/tools/md_cdrom.dart /tmp/md-cdrom-bios.bin \
  <disc.cue> 1800 \
  --start-frame=600 --out=/tmp/md-cdrom-check --every=300
"$SDK/cache/dart-sdk/bin/dart" --packages=.dart_tool/package_config.json \
  lib/tools/md_32x.dart /tmp/md32x-cart.32x \
  /tmp/md32x-main-boot.bin /tmp/md32x-master-boot.bin \
  /tmp/md32x-slave-boot.bin 600
"$SDK/flutter" test --no-pub --reporter expanded
"$SDK/cache/dart-sdk/bin/dart" analyze lib/core/md lib/core/types.dart \
  lib/core/core_factory.dart lib/disc/cue.dart lib/tools/md_32x.dart \
  lib/tools/md_cdrom.dart test/core/md/32x test/core/md/md_cdrom_test.dart \
  test/disc/md_cdrom_disc_test.dart
```

## 次の調査

1. 実ディスク 起動待ち: BIOS が CDC の転送開始を書かない理由を、セクタ 0 前後のデコーダ割り込みから追う。CDC レジスタ値だけを修正しても起動待ちは解消しなかった。
2. CDC の最後のサンプルは header=[0,21,33,1], destination=0, dataReady=false, transferEnd=false。これは単一時点であり、DMA 未実行と断定しない。
3. main は 0x10ec/0x10f0 の sub flag bit 1 待ち。sub は 0x6156/0x615a の local flag 待ち。sub の flag 0x8c35 は IRQ2 handler 0x60a4 で実際にクリアされる。IRQMASK=62、main reset read=0x8001。
4. 再起動やゲーム固有の待ちを直す場合は、BIOS PC を強制変更するなどの回避ではなくハードウェア原因を確認する。
5. 32x は実 ROM の対戦 HUD と背景まで確認済み。ただしキャラクターは表示されない。DIV1 はメーカーの命令仕様に沿って追加し、16-bit 非符号除算シーケンスで確認した。MAC.L と MAC.W も追加済み。キャッシュデータ領域以外のキャッシュ制御、on-chip peripherals/DMAC、正確な timing、PAL/240 line と GUI BIOS selector は未実装。未実装 opcode は停止して表示する。

通常 MD の AOT 比較は `/tmp/md_perf.dart` と `/tmp/md_perf_{base,current}` で試行。
サンプルは大きくばらつき、定量的に「速度低下なし」とはまだ言えない。
直近の専用バスへの変更後は再ビルドが必要。実ゲームや安定した環境で比較する。

## 区切り時点の検証

- MAC.W テスト追加後、全 133 テスト成功。
- 変更対象の Dart static analysis: No issues found。
- `git diff --check` 成功。
- 専用 32x バスへの整理後に実 BIOS の 1800-frame 確認を再実行。CDC 状態修正後も起動待ちのまま。上記ログを参照する。
