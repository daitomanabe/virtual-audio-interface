# Virtual Audio Interface

空間オーディオのデバッグ用に作った、macOS 向けの 128ch 仮想オーディオインターフェースと可視化アプリです。
DAW からは普通の出力デバイスとして見え、各チャンネルに何が届いているか、スピーカー配置(`.sscene`)の
どのスピーカーから鳴るはずかを表示します。

[English README](README.md)

![Monitor タブ: .sscene のスピーカー配置、ライブのレベル、ルーティング警告](docs/images/monitor-perspective.png)

## なぜ作ったか

空間オーディオのデバッグは、ふつう実際のスピーカーシステムの前でしかできません。ch17 は本当に天井の
スピーカーか、パンナーが Mute のスピーカーに信号を送っていないか、誰も聴いていないチャンネルにバスが
流れていないか。こうした確認を、現場以外でもできるようにしたくて作りました。

Ableton Live などからは本物のオーディオインターフェースとして認識されるので、信号の流れは現場と同じまま
です。アプリはその結果を、チャンネルごとのメーター、鳴っているスピーカーが光る 3D 配置図、ルーティングの
警告として見せます。

## 機能

- **仮想出力デバイス**: 最大 128ch、44.1 / 48 / 88.2 / 96 kHz。Core Audio の HAL プラグイン
  (AudioServerPlugIn)として実装しています。チャンネル数とサンプルレートはアプリから変更できます。
- **Meters**: 全チャンネルの dBFS メーター(RMS、ピーク、ピークホールド、ラッチ式クリップ表示)。
  メーターはウィンドウいっぱいに伸びます。**All channels** は 1〜128 を順に、**Layout** は読み込んだ配置の
  チャンネルをスピーカーの高さの層ごとにまとめて表示します([Meters](#meters) を参照)。スピーカーがないのに
  信号が来ているチャンネルには *NO SPK*、全スピーカーが Mute / 無効のチャンネルは灰色で *MUTE* / *OFF* と出ます。
- **Monitor**: SSD(`.sscene`)のスピーカー配置を、平面図、正面 / 側面の立面、自由視点の 3D で表示します。
  スピーカーはレベル(既定では入力レベル + 配置ファイルの Gain)に応じて光り、リスナー位置から発音中の
  スピーカーへ線を引くこともできます。同じファイルのスクリーン、LED ウォール、プロジェクター、カメラ、
  BOX、FOV も参考として描きます。スピーカーをクリックすると、全画面で同じチャンネルが選択されます。
  ファイルを保存すると自動で読み直します。
- **ルーティング検証**: 未割当チャンネルへの信号、デバイスのチャンネル数を超えるスピーカー、
  Mute / 無効なスピーカーへの信号、複数スピーカーでのチャンネル共有、パーサー警告。
- **テスト信号**: ピンクノイズまたはサイン波を仮想デバイスに出します。選択中のチャンネル、配置のスピーカーを
  順に、全チャンネルを順に、全チャンネル同時、から選べるので、DAW なしで経路全体を確認できます
  ([テスト信号](#テスト信号) を参照)。
- **ホストが決める値の表示**: IO バッファサイズ、動作状態、クライアント数、DAW が要求したサンプルレート。
  ホストと実際に何が取り決められたかを確認できます。
- **ドライバの ON / OFF / Update** を右上のドライバメニューから実行できます。OFF のときは、ドライバの
  プロセスが本当に終了したことまで確認します。

アプリの表示は英語です。

| Meters | Settings |
|---|---|
| ![Meters タブ](docs/images/meters.png) | ![Settings タブ](docs/images/settings.png) |

![Monitor タブ(平面図、Channel + 名前のラベル)](docs/images/monitor-top.png)

## 動作環境

- macOS 13 以降、Apple silicon / Intel(Universal バイナリ)
- Core Audio デバイスに出力できる DAW などのアプリ

## インストール

1. [Releases](https://github.com/daitomanabe/virtual-audio-interface/releases) から
   `VirtualAudioInterface-<version>.pkg` をダウンロードします。
2. パッケージは公証(notarize)されていないため、最初に開こうとすると macOS にブロックされます。
   一度開いてから **システム設定 → プライバシーとセキュリティ** で、パッケージについての表示の横にある
   **このまま開く** をクリックしてください。ターミナルで隔離属性を外す方法もあります。
   ```bash
   xattr -d com.apple.quarantine ~/Downloads/VirtualAudioInterface-0.3.2.pkg
   ```
3. インストーラーを実行します。次の 2 つが入ります。
   - `/Applications/VirtualAudioInterface.app`
   - `/Library/Audio/Plug-Ins/HAL/VirtualAudioInterfaceDriver.driver`

   ドライバを読み込むために `coreaudiod` を再起動するので、**その間は Mac のすべてのオーディオデバイスが
   1〜2 秒途切れます**。

### アンインストール

アプリを終了してから [`packaging/uninstall.sh`](packaging/uninstall.sh)(各リリースにも添付)を実行します。

```bash
sudo ./uninstall.sh
```

アプリとドライバを削除し、パッケージの記録を消して `coreaudiod` を再起動します。
アプリは残してドライバだけを外すときは、アプリのドライバメニューの **Turn Driver Off** を使ってください。

## 使い方

1. **Virtual Audio Interface** を開きます。右上の点が緑ならドライバが読み込まれています。隣のメニューで
   ドライバの ON / Update / OFF と詳細を確認できます。
2. DAW の出力デバイスに、初期状態では **Virtual Audio Interface (128ch)** を選びます。
   Settings でチャンネル数を変更すると、デバイス名も `(24ch)` のように追従します。
   Ableton Live では *設定 → オーディオ → オーディオ出力デバイス* で選び、*出力設定* で使うチャンネルを
   有効にします。
3. **Open…**(⌘O)で配置ファイルを開くか、`.sscene` をウィンドウにドロップします。
   まずはスクリーンショットと同じ [`Examples/FIL-v1.sscene`](Examples/FIL-v1.sscene) を試してください。
   実在の部屋の配置で、スピーカー 16 本、ムービングライト、プロジェクターと壁面の投影範囲を含みます
   (チャンネルの割り当ては仮のものです。ファイル内の注記を参照)。
   [`Examples/dome-24.sscene`](Examples/dome-24.sscene) はゲイン、ディレイ、ミュートを含む 24 本のドーム、
   [`Examples/venue-demo.sscene`](Examples/venue-demo.sscene) はスクリーン、LED ウォール、プロジェクター、
   カメラを含む例です。
4. 再生すると、**Monitor** タブで信号が来ているスピーカーが光り、**Meters** で全チャンネルが見えます。
   DAW がないときは **Test signal**(2 段目の右)を使えます。

上段にはファイル名と読み込んだ時刻、デバイスの形式(例: *128 ch · 48 kHz*)、ドライバの状態が並びます。
2 段目は表示中のタブの操作(Monitor: カメラのプリセットと **View** メニュー[発音ライン、シーンの要素、
Apply SSD gain、ラベル]、Meters: All channels / Layout と Reset Clips)と、テスト信号です。
3D 表示とメーターはライトモードでも暗い背景のままです。

次回起動時は最後に開いた配置を自動で開きます。エディタでファイルを保存すると自動で読み直し、視点と選択は
そのまま残ります。保存途中などで読めないときは、直前の正常な内容を表示したままエラーを帯で表示します。
**Reload**(⌘R)はファイルを読み直して視点も合わせ直します。

## Meters

**All channels** はデバイスの全チャンネルを順に表示します。**Layout** は `.sscene` を読み込んでいるときに
使え、配置のチャンネルをスピーカーの高さの層ごとに、高いほうから表示します(Z が隣のスピーカーと 0.5 m より
離れたところで次の層に分けます)。各層の見出しは *z ≈ 2.7 m · 6 speakers* のようになります。どのスピーカーにも
使われていないのに -60 dBFS を超える信号があるチャンネルは、最後に **Unassigned with signal** としてまとめます。
層はウィンドウの幅に沿って並び、メーターは高さいっぱいに伸びます。メーターをクリックすると、全画面でその
チャンネルが選択されます。

| 表示 | 意味 |
|---|---|
| 赤枠と *NO SPK* | スピーカーのないチャンネルに信号がある |
| 灰色のバーと *MUTE* / *OFF* | そのチャンネルの全スピーカーが Mute / 無効。信号が来ている間は橙の枠 |
| 上端の赤い点 | クリップした(**Reset Clips** まで点灯したまま) |

## テスト信号

テスト信号はアプリ自身が仮想デバイスに出力します(DAW の出力とはミックスされます)。DAW なしで Monitor /
Meters タブ、ルーティング検証、スピーカー配置を確認できます。ドライバが ON のときに使えます。

- **信号**: ピンクノイズ、または 63 Hz〜8 kHz のサイン波。**レベル**: -60〜0 dBFS(サイン波はピーク、
  ピンクノイズは RMS)。
- **出力先**:
  - **Selected channel**: 3D 表示、スピーカー一覧、メーターで選択中のチャンネル
  - **Step through SSD speakers**: 配置の有効で Mute でないスピーカーのチャンネルを順に
  - **Step through all channels**: デバイスのチャンネル 1〜N を順に
  - **All channels at once**: 全チャンネル同時
- **Dwell**(順に鳴らすとき): 1 チャンネルあたり 0.25〜5 秒。鳴っているチャンネルに選択が移るので、
  3D 表示、一覧、メーターが追従します。

止めたとき、ウィンドウを閉じたとき、アプリを終了したときに停止します。ウィンドウなしでターミナルからも
鳴らせます。

```bash
dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --test-signal <channel> <seconds> [pink|sine] [dBFS]
# 例: ch17 にピンクノイズを -20 dBFS で 2 秒(sine は 1 kHz)
dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --test-signal 17 2 pink -20
```

## スピーカー配置(SSD / .sscene)

**Layouts** メニューには `~/Library/Application Support/VirtualAudioInterface/Scenes/` の
`.sscene` ファイルが表示されます。**Show Layout Folder** でフォルダを開いて配置ファイルをコピーし、
**Refresh Layouts** で一覧を更新できます。ここに置いたファイルはローカルデータであり、公開リポジトリや
配布アプリには含まれません。

**Debug Log** タブには、SSD の読み込み、ステップ対象チャンネル、テスト信号の出力先、デバイスの変化と
出力エラーが表示されます。**Copy Log** で現在のログをコピーできます。`[OBJECT]` にスピーカーがあっても
`[SPEAKER]` のチャンネル割り当てがなければ **Step: SSD speakers** の対象にはなりません。

配置は SSD(Spatial Scene Definition)v0.1 というタブ区切りテキスト形式で書きます。形式の仕様は
[daitomanabe/ssd-format](https://github.com/daitomanabe/ssd-format) にあります。スピーカーは下の
セクションで定義します。シーンのそれ以外の要素も参考として描きます([シーンの要素](#シーンの要素) を参照)。

```text
[SCENE]
Version	0.1
Name	ring-8
Unit	meter
CoordinateSystem	SSD_RH_ZUP
AngleUnit	degree

[OBJECT]
# ID	Type	Name	Parent	X	Y	Z	Yaw	Pitch	Roll	Enabled
1	speaker	SP1	none	0.000	3.000	1.2	0	0	0	1
2	speaker	SP2	none	2.121	2.121	1.2	0	0	0	1

[SPEAKER]
# ID	Channel	Gain	Delay	Mute
1	1	0	0	0
2	2	0	0	0
```

- 右手系で、**+X が右、+Y が前、+Z が上**。単位はメートルと度です。
- `Parent` には別の OBJECT(または `none`)を指定します。ワールド変換は
  親 × T(X,Y,Z) × Ry(Roll) · Rx(Pitch) · Rz(Yaw) です。自分か祖先のどれかが `Enabled` 0 なら無効になります。
- `[SPEAKER]` は type が `speaker` の OBJECT を 1 始まりの出力チャンネルに割り当てます。`Gain` は dB、
  `Delay` はミリ秒、`Mute` は 0/1。1 つのチャンネルを複数のスピーカーで共有してもかまいません。
- `[REVIEW_VOLUME]`(Width, Depth, Height)は情報として表示するだけです。
- SSD にはスピーカーの正面方向の定義がないため、スピーカーの向きは描いていません。
- **Apply SSD gain**(View メニュー、既定 ON)では、入力レベル + `Gain`(スピーカーから出る想定のレベル)で
  スピーカーを光らせます。スピーカー一覧には両方の値を表示し、レベルバーは 3D 表示の基準になっている列に出ます。
  Mute と無効のスピーカーは信号があっても光らず、半透明で表示します(Mute には ×)。そのチャンネルに信号が
  来ている間は橙になります。**Channel + name** ラベル(View メニュー)には 0 でない `Gain` / `Delay` を添えます。

### シーンの要素

**View → Scene objects**(既定 ON)のとき、スピーカー以外の OBJECT を控えめな色で描きます。

| セクション / type | 描き方 |
|---|---|
| `[SCREEN]` / `[SURFACE]`(Width, Height) | 半透明の面と輪郭、前面(+Z)側への短い線 |
| `[LED]`(Width, Height, PixelWidth, PixelHeight) | 同上 + 粗いピクセルグリッド |
| `[BOX]`(SizeX, SizeY, SizeZ)、type は問わない | オブジェクト中心のワイヤーフレーム |
| `[FOV]`(Horizontal, Vertical, Distance)、type は問わない | 視錐台 |
| type `camera` / `projector` | 小さな錐体(`[CAMERA]` があれば FovH / FovV の形) |
| `[PROJECTOR]` の TargetID | プロジェクターから投影先への点線 |
| それ以外の type(microphone など) | 小さなマーカー。他の要素をまとめるだけのリグにはラベルを付けない |

矩形は仕様どおり、ローカル X が右、Y が上、+Z が前面の法線で、中心が原点です。`(Yaw, Pitch, Roll) = (0, 90, 0)`
で直立し、world −Y を向きます。形式の仕様書はカメラ、プロジェクター、FOV の光軸を文章では定めていませんが、
参照ビューアが FOV をローカル (±w, ±h, +Distance) に描き、部屋のデータセットも同じ規約を宣言しています。
そのため **このアプリではローカル +Z 方向を見ているもの**として描きます。つまり `(0, −90, 0)` で world +Y、
`(0, 180, 0)` で真下を向きます。姿勢は B·M·B⁻¹
(`ssdb_matrix_to_scenekit`)で SceneKit に渡し、Euler 角を流用しません。値が不正な行は読み飛ばして
パーサー警告にし、スピーカーは通常どおり読み込みます。`[REVIEW_VOLUME]` は描きません。

パーサー([`ssd_reader.h`](VisualizerApp/Sources/SSDBridge/ssd_reader.h))は仕様から独自に実装したもので、
[daitomanabe/ssd-format](https://github.com/daitomanabe/ssd-format) の参照実装と突き合わせてあります
(全サンプルシーンで、ワールド変換・有効状態・SPEAKER の値・警告が一致)。ヘッダー、数値、親の参照、
循環参照を検証し、エラーは行番号付きで表示します。

### ルーティング警告

| 警告 | 条件 |
|---|---|
| 未割当(赤) | -60 dBFS を超える信号があるのに、読み込んだ配置にそのチャンネルのスピーカーがない |
| 範囲外(赤) | スピーカーのチャンネルが、デバイスの有効チャンネル数を超えている |
| Mute / 無効(橙) | Mute または無効なスピーカーのチャンネルに信号がある |
| パーサー(橙) | 未知のセクションなどのパーサー警告 |
| チャンネル共有(青) | 同じチャンネルを複数のスピーカーが使っている(情報) |

## 設定とホストが決める値

| アプリから設定 | 範囲 |
|---|---|
| チャンネル数 | 1〜128 |
| サンプルレート | 44100 / 48000 / 88200 / 96000 Hz |

**IO バッファサイズはドライバではなくホスト(DAW)が決める**ため、表示だけで設定はできません。
Settings タブでは、実際に有効なサンプルレート、動作状態、クライアント数、ホストが最後に要求したレート、
設定変更が適用済みかどうかも確認できます。

## 仕組み

```text
 DAW ──Core Audio (最大 128ch)──▶ HAL プラグイン ──POSIX 共有メモリ──▶ アプリ
                                  (coreaudiod の                         ├─ Meters
                                   ドライバ用プロセスで動く)             ├─ Monitor ◀── .sscene
                                                                        └─ Settings ──設定──▶ プラグイン
```

- プラグイン([`VirtualAudioDevicePlugin.cpp`](HALPlugin/src/VirtualAudioDevicePlugin.cpp))は、出力デバイス
  1 つを持つ AudioServerPlugIn を一から実装したものです。IO サイクルごとにチャンネル別のピーク、RMS、
  クリップ回数を計算します。ピークには減衰処理をかけ、アプリの 60 Hz ポーリングでも短いピークを
  取りこぼさないようにしています。
- レベルとデバイス状態は、固定サイズの共有メモリ([`MeterShm.h`](Shared/MeterShm.h))でやり取りします。
  アプリはチャンネル数とサンプルレートの変更要求を同じ領域に書き、プラグインは標準の
  `RequestDeviceConfigurationChange` の手順で適用します。
- ドライバの ON では `/Library/Audio/Plug-Ins/HAL` にコピーして `coreaudiod` を再起動します。OFF では削除して
  再起動し、`Core Audio Driver (VirtualAudioInterfaceDriver.driver)` プロセスとデバイスが消えたことを
  確認します(残ったプロセスは PID を指定して強制終了します)。

## ソースからビルド

Command Line Tools だけでビルドできます(Xcode は不要です)。

```bash
./build_app.sh                 # ドライバ + dist/VirtualAudioInterface.app(Universal)
open dist/VirtualAudioInterface.app --args "$PWD/Examples/dome-24.sscene"
packaging/build_pkg.sh         # dist/VirtualAudioInterface-<VERSION>.pkg と .sha256
```

`HALPlugin/install.sh` は、ビルドしたドライバを直接インストールする開発用のスクリプトです。
バージョンは [`VERSION`](VERSION)、ビルド番号はコミット数から付けます。

### テストとツール

```bash
make -C Tools check            # 共有メモリとメーターの減衰計算、SSD パーサー、シーン要素と座標変換、
                               # テスト信号の生成、ファイル監視
make -C Tools harness          # coreaudiod と同じ呼び出しでプラグインを ASan/UBSan 検査
```

- `dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --status` でドライバの状態を表示します。
- `... --docshot <dir> [scene.sscene] [--appearance light|dark] [--size WxH]` で全タブを PNG に書き出します
  (上のスクリーンショットもこれで撮影。ウィンドウは `--size` の指定がなければ 1400×900 pt)。
- `... --test-signal <channel> <seconds> [pink|sine] [dBFS]` でウィンドウなしで[テスト信号](#テスト信号)を鳴らします。
- `swift packaging/icon/make_icon.swift` でアプリアイコン(`packaging/icon/AppIcon.icns`)を描き直します。
- `Tools/fake_meter [sweep|sine|clip]` は DAW なしで合成レベルを書き込みます。ドライバと同じ共有メモリを
  使うので、ドライバが OFF のときだけ使ってください。

## ディレクトリ構成

```text
HALPlugin/        Core Audio HAL プラグイン(C++)、Makefile、開発用インストールスクリプト
Shared/           プラグインとアプリが共有するメモリレイアウト
VisualizerApp/    Swift パッケージ: SwiftUI アプリ、AudioBridge(共有メモリ)、SSDBridge(SSD パーサー)、
                  TestSignalDSP(テスト信号の生成)
Tools/            セルフチェック、HAL 検査ツール、fake meter
Examples/         サンプルの .sscene
packaging/        インストーラー(pkg)のビルド、アンインストールスクリプト、アプリアイコン
```

## TODO

詳細は [TODO.md](TODO.md)(英語)にあります。主な項目は次のとおりです。

- **UI の洗練**: メーターの表示切替(横一列、ズーム、dB 目盛り、マウスオーバーで値)、近いスピーカーの
  ラベルの重なり解消と凡例、ルーティング一覧の並べ替えと検索、メニューバー常駐、初回起動ガイド
- **テスト機能**: 実オーディオインターフェースへのパススルー、rE / rV ベクトル表示、メーターの記録と再生、
  OSC 出力
- **ドライバ**: チャンネル数に合わせたデバイス名、HAL コントロールとしてのミュート / トリム、
  ループバック入力、共有メモリの設定領域の保護、パスワード入力なしの ON/OFF(特権ヘルパー)
- **配布**: Developer ID 署名と公証、GitHub Actions、Homebrew cask

## 関連

- [daitomanabe/ssd-format](https://github.com/daitomanabe/ssd-format) — `.sscene` 形式が公開されていた場所。
  仕様、参照実装とビューア、サンプルシーンは `daitomanabe/spatial-scene-definition` に移りました

## ライセンス

[MIT](LICENSE) Copyright (c) 2026 Daito Manabe
