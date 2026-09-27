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
"$SDK/flutter" test --no-pub --reporter expanded
"$SDK/cache/dart-sdk/bin/dart" analyze lib/core/md lib/core/types.dart \
  lib/core/core_factory.dart lib/disc/cue.dart lib/tools/md_32x.dart \
  lib/tools/md_cdrom.dart test/core/md/32x test/core/md/md_cdrom_test.dart \
  test/disc/md_cdrom_disc_test.dart
```

## 次の調査

1. 実ディスク 起動待ち: CDC の初期セクタ受け取り、ヘッダ/STAT/IFSTAT、host transfer/DMA と BIOS の読み込み終了判定を追う。
2. CDC の最後のサンプルは header=[0,21,33,1], destination=0, dataReady=false, transferEnd=false。これは単一時点であり、DMA 未実行と断定しない。
3. main は 0x10ec/0x10f0 の sub flag bit 1 待ち。sub は 0x6156/0x615a の local flag 待ち。sub の flag 0x8c35 は IRQ2 handler 0x60a4 で実際にクリアされる。IRQMASK=62、main reset read=0x8001。
4. 再起動やゲーム固有の待ちを直す場合は、BIOS PC を強制変更するなどの回避ではなくハードウェア原因を確認する。
5. 32x は commercial boot 未検証。DIV1/MAC、on-chip peripherals/DMAC/cache、正確な timing、PAL/240 line と GUI BIOS selector が未実装。未実装 opcode は停止して表示する。

通常 MD の AOT 比較は `/tmp/md_perf.dart` と `/tmp/md_perf_{base,current}` で試行。
サンプルは大きくばらつき、定量的に「速度低下なし」とはまだ言えない。
直近の専用バスへの変更後は再ビルドが必要。実ゲームや安定した環境で比較する。

## 区切り時点の検証

- 専用バスへの切り替えと通常 ROM 復帰の変更後、全 123 テスト成功。
- 変更対象の Dart static analysis: No issues found。
- `git diff --check` 成功。
- 実 BIOS の 1800-frame 確認は専用 32x バスへの整理前に実行。CD 専用モードで 32x は生成されないため処理経路は同じだが、再開時は上記コマンドで再実行すること。
