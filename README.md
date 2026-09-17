# virtual-audio-interface

macOS向け「仮想オーディオインターフェース + スピーカー3D可視化アプリ」。
Ableton Live 等から仮想オーディオデバイスとして接続し、受信した信号を
チャンネル別レベルメーターと、.sscene (SSD) で定義したスピーカーの3D配置に
重ねて可視化する。

## アーキテクチャ

```
 Ableton Live などの DAW
        │ (Core Audio, 128ch out)
        ▼
┌─────────────────────────────┐        POSIX共有メモリ         ┌───────────────────────────┐
│ HALPlugin (別プロセス:        │  /vai_meter_v1 (mmap, 読専)   │ VisualizerApp (SwiftUI)    │
│ coreaudiod にロードされる)     │ ───────────────────────────▶ │                            │
│  AudioServerPlugIn.h の      │  VAIMeterShm{ channelCount,   │  AudioLevelsModel          │
│  COM風インターフェースを実装   │    peakLevel[128] }           │   30Hzポーリングで読み出し   │
│  ・仮想入力デバイスとして登録   │                                │  LevelMeterGridView        │
│  ・IOProcでオーディオ受信      │                                │   128ch グリッドメーター    │
│  ・チャンネル毎にabs peak計算  │                                │  SpeakerSceneView          │
│  →共有メモリへ書き込み         │                                │   SceneKit + SSD反映        │
└─────────────────────────────┘                                └─────────────┬──────────────┘
                                                                                │
                                                                        .sscene ファイル
                                                                                ▼
                                                                     SSDBridge (C++/Cブリッジ)
                                                                       ssd::Scene (Scene.h を
                                                                       vendoring・ラップ)
                                                                       SPEAKER Channel→World座標
```

### プロセス間通信の設計判断: 共有メモリ vs XPC

**共有メモリ (POSIX shm, `shm_open`/`mmap`) を採用した。** 判断理由:

- HAL Plugin は `coreaudiod` にロードされる別プロセスであり、そこから
  App へ**継続的に**(理想は各 IOProc サイクル毎に)128ch分のレベル値を
  送る必要がある。XPC はメッセージ単位のオーバーヘッドが大きく、
  リアルタイムオーディオコールバック内から呼ぶには不向き。
- 今回送るデータは「128ch分の peak float 配列」という固定サイズ・
  高頻度更新のデータであり、まさに共有メモリが得意とする形。
  XPCは将来「デバイス選択・ゲイン設定などの低頻度コマンド」を
  App→HALPlugin 方向に送る用途に使うのが自然(未実装、ロードマップ参照)。
- 排他ロックなしの単一ライター/複数リーダー構成にした
  (`Shared/MeterShm.h` 参照)。メーター用途であれば稀な torn read は
  実用上問題にならないため、ロックのコストを避けた
  (ponytail: 将来レベル値以外の重要データを載せるなら再検討する)。

### 座標系変換 (SSD → SceneKit)

SSD は右手系・+Z-up・メートル単位。SceneKit は右手系・+Y-up。
`Scene.h` が openFrameworks 向けに例示する変換 `(x, y, z) → (x, z, -y)` は
「+Z-up → +Y-up」の回転であり、SceneKit も同じ右手系+Y-upなので
**同じ変換式がそのまま使える**(`VisualizerApp/Sources/SSDBridge/ssd_bridge.cpp`
の `ssdb_load_speakers` 参照)。

## 設定可能パラメータ / ホスト決定パラメータ

VisualizerApp の Settings タブから、共有メモリ (`Shared/MeterShm.h` v2) 経由で
HAL Plugin に設定を要求できる。HAL Plugin 側は `Plugin_Initialize` で起動する
200ms 周期の `dispatch_source_t` タイマーが shm の `configCounter` を監視し、
変化していれば `requestedChannelCount` / `requestedSampleRate` を検証した上で
`RequestDeviceConfigurationChange` → `Plugin_PerformDeviceConfigurationChange`
経由で適用する(IO スレッドからは直接呼ばない)。

| パラメータ | 設定元 | 範囲 | shm フィールド |
|---|---|---|---|
| チャンネル数 | アプリ (Settings タブ) | 1〜128 | `requestedChannelCount` → `channelCount` |
| サンプルレート | アプリ (Settings タブ) | 44100 / 48000 / 88200 / 96000 Hz | `requestedSampleRate` → `sampleRate` |

**IO バッファサイズは HAL クライアント(DAW)が決めるため、plugin 側からは設定できない。**
`Plugin_DoIOOperation` に渡される `inIOBufferFrameSize` を読み取って可視化するのみ。

| ホスト決定値 (読み取り専用) | shm フィールド | 更新元 |
|---|---|---|
| 実際の IO バッファフレーム数 | `ioBufferFrameSize` | `Plugin_DoIOOperation` |
| 実際に有効なサンプルレート | `sampleRate` | `Plugin_PerformDeviceConfigurationChange` |
| Running 状態 | `isRunning` | `Plugin_StartIO` / `Plugin_StopIO` |
| 接続クライアント数 | `clientCount` | `Plugin_AddDeviceClient` / `Plugin_RemoveDeviceClient` |
| ZeroTimeStampPeriod | `zeroTimeStampPeriod` | `Plugin_Initialize` (固定値を publish) |
| 最後に DAW から要求されたサンプルレート | `hostRequestedSampleRate` | `Plugin_SetPropertyData` |
| 設定適用済みか | `configAppliedCounter` == `configCounter` | `Plugin_PerformDeviceConfigurationChange` / poll timer |

設定変更の適用経路は HAL 標準のプロトコルに統一されている:
`RequestDeviceConfigurationChange` の `inChangeAction` は常に「pending 設定を適用せよ」
を意味する定数 (`kApplyPendingConfigAction`) のみを運び、実際の新レート/新チャンネル数は
`gPendingSampleRate` / `gPendingChannelCount` (mutex 保護のグローバル変数) 経由で渡す。
適用後は `kAudioStreamPropertyVirtualFormat` / `PhysicalFormat` と、デバイスの
`kAudioDevicePropertyNominalSampleRate` / `kAudioDevicePropertyPreferredChannelLayout` の
変更を `PropertiesChanged` で通知し、HAL / DAW 側がストリームフォーマット変更を認識できるようにしている。

**注意: shm の config 領域(app → driver)はロックなしで、同一マシン内であれば
任意のプロセスから書き込める。** ローカルユーザーのみが信頼される前提であり、
リモート/マルチユーザー環境での保護は行っていない(ローカル単一ユーザー利用前提)。

## ディレクトリ構成

```
virtual-audio-interface/
├── Shared/
│   └── MeterShm.h            # HALPlugin・App 共通の共有メモリ構造体定義
├── HALPlugin/                # Core Audio AudioServerPlugIn (HAL Plugin) 本体
│   ├── src/VirtualAudioDevicePlugin.cpp
│   ├── Info.plist
│   └── Makefile               # clang++ で .driver バンドルをビルド
└── VisualizerApp/             # Swift Package (SwiftUI アプリ)
    ├── Package.swift
    └── Sources/
        ├── SSDBridge/         # Scene.h を vendoring した C++/Cブリッジ
        │   ├── ssd_bridge.cpp
        │   └── include/
        │       ├── ssd_bridge.h
        │       ├── module.modulemap   # Scene.h をSwift側へ露出させない
        │       └── ssd/Scene.h        # spatial-audio-kit-and-ssd-v4 からコピー
        ├── AudioBridge/       # 共有メモリ読み出し (C)
        │   ├── audio_bridge.c
        │   └── include/{audio_bridge.h, MeterShm.h}
        └── VisualizerApp/     # SwiftUI 本体
            ├── App.swift
            ├── ContentView.swift
            ├── AudioLevelsModel.swift   # 30Hzポーリングで共有メモリを読む
            ├── SSDSceneModel.swift      # .sscene ロード
            ├── LevelMeterGridView.swift # 128ch バーメーター (有効チャンネル数以外は減光)
            ├── SettingsView.swift       # チャンネル数/サンプルレート設定 + ホスト決定値表示
            └── SpeakerSceneView.swift   # SceneKit 3D表示 + レベル反映
```

## 実装ロードマップ

### 完了 (このセッション)
- [x] プロジェクト構成・アーキテクチャ設計
- [x] HAL Plugin 128ch実装 (Output ストリーム、`WriteMix` からのpeak計算、
      共有メモリへの publish、clang++でビルド確認)
- [x] SwiftUI アプリ雛形 (128ch レベルメーターグリッド、共有メモリ読み出し、
      peak-hold/decay ballistics)
- [x] SSDBridge (Scene.hラップ、SPEAKER Channel→World座標、SceneKit軸変換)
- [x] SceneKitでのスピーカー3D表示 + レベルに応じた発光・拡大
      (.sscene 再ロード時のシーン再構築込み)
- [x] `swift build` / `make` (HALPlugin) の両方でビルド確認済み

### Output ストリーム化 (このセッション)
DAW (Ableton Live 等) は仮想デバイスに対して**出力**するため、ストリーム方向を
Output (`kAudioStreamPropertyDirection` = 0) に変更した。`Plugin_DoIOOperation`
は `kAudioServerPlugInIOOperationWriteMix` を処理し、HALが混合(ダウンミック
ス済み)した `ioMainBuffer` から直接チャンネル別 abs peak を計算する
(旧 `ReadInput` 経路・中間コピー用リングバッファは削除)。`Plugin_GetZeroTimeStamp`
も `mach_absolute_time` + `mach_timebase_info` でHALクロックを正しく進めるように
実装した。

### 可変サンプルレート対応 (このセッション)
`kAudioDevicePropertyNominalSampleRate` を 44100/48000/88200/96000 Hz で
setting 可能にした。設定要求は `RequestDeviceConfigurationChange` →
`Plugin_PerformDeviceConfigurationChange` を経由し、実際のレート切り替え
(`gSampleRate` 更新・ゼロタイムスタンプの周期再計算)はそこで行う
(`gStateMutex` で保護)。`kAudioStreamPropertyVirtualFormat` /
`AvailableNominalSampleRates` もこの4レートを反映する。

### チャンネル数・サンプルレートのアプリ設定化 (このセッション)
shm を v2 レイアウト (`/vai_meter_v2`) に更新し、driver→app のステータス半分
(IOバッファフレーム数・Running・クライアント数・ZeroTimeStampPeriod・ホスト要求
レート) と app→driver の設定半分 (requestedChannelCount/requestedSampleRate +
configCounter) を追加。HAL Plugin は 200ms 周期のポーリングタイマーで設定要求を
検知し、`RequestDeviceConfigurationChange` の標準プロトコルに統一して適用する
(詳細は上の「設定可能パラメータ / ホスト決定パラメータ」参照)。VisualizerApp
には Settings タブを追加した。

### 未実装・残課題
- [ ] **実機インストール手順の整備 (未検証)**: `.driver` バンドルを
      `/Library/Audio/Plug-Ins/HAL/` に配置し、コード署名 or SIP無効化、
      `sudo killall coreaudiod` で再読込する手順のドキュメント化と検証。
      本セッションではコンパイル確認までで、実機インストールは未検証。
- [ ] **XPC (低頻度コマンド経路)**: App→HALPluginへのミュート/ゲイン設定
      などの制御コマンド送信。共有メモリと役割分担する設計。
- [ ] **HAL Plugin側のプロパティ実装の充実**: 現状は読み取り専用の
      最小プロパティセットのみ。ミュート/ボリュームコントロール、
      複数クライアント対応、実際のストリームフォーマット変更通知等。
- [ ] **共有メモリの堅牢化**: HALPluginが未起動/クラッシュした場合の
      Appの復帰、shmセグメントの権限・サンドボックス対応。
- [ ] **SceneKit UI改善**: カメラの初期アングル調整、スピーカーIDラベル表示、
      Mute状態の視覚表現、Gain値の反映。
- [ ] **配布**: コード署名・notarization・インストーラ(pkg)化は未着手。

## ビルドと起動

```bash
./build_app.sh   # HAL ドライバ + dist/VAIControl.app + dist/VirtualAudioVisualizer.app
open dist/VAIControl.app
open dist/VirtualAudioVisualizer.app --args "$PWD/Examples/ring-8.sscene"
```

`swift run` で実行ファイルを直接起動すると SwiftUI がウィンドウを作らないため、
必ず `.app` から起動する。ヘッドレス確認は `dist/VAIControl.app/Contents/MacOS/VAIControl --status`、
`make -C Tools check`(SSD 軸変換と共有メモリ読み出し)。

## VAIControl (ドライバ ON/OFF)

| 操作 | 実行内容 (管理者権限) | 完了判定 |
|---|---|---|
| ON | 同梱ドライバを `/Library/Audio/Plug-Ins/HAL/` へコピー → `killall coreaudiod` | バンドル配置 + ヘルパープロセス存在 + CoreAudio にデバイス UID 登録 |
| OFF | バンドル削除 → `killall coreaudiod` | バンドルなし + ヘルパープロセスなし + デバイスなし。15 秒以内に消えないヘルパーは PID 指定で `kill -9` |

- HAL プラグインは coreaudiod 配下の専用プロセス `Core Audio Driver (VirtualAudioInterfaceDriver.driver)` で動く。
  このプロセスだけ kill しても coreaudiod が再起動し得るため、バンドル削除 + coreaudiod 再起動で止める。
- coreaudiod 再起動中は **他のオーディオデバイスも一瞬途切れる**。本番中の切り替えは避ける。
- `HALPlugin/install.sh` は開発用(ビルド直後のドライバを直接インストール)。

## 参照

- SSD フォーマット仕様: `spatial-audio-kit-and-ssd-v4/ssd/docs/ssd-format-ai-spec.md`
- リファレンス実装: `spatial-audio-kit-and-ssd-v4/ssd/include/ssd/Scene.h`
  (このリポジトリの `VisualizerApp/Sources/SSDBridge/include/ssd/Scene.h` に
  コピーして vendoring。将来アップデートする際は手動同期が必要)
