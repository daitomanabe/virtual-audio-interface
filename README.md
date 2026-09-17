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
            ├── LevelMeterGridView.swift # 128ch バーメーター
            └── SpeakerSceneView.swift   # SceneKit 3D表示 + レベル反映
```

## 実装ロードマップ

### 完了 (このセッション)
- [x] プロジェクト構成・アーキテクチャ設計
- [x] HAL Plugin 最小実装 (16ch, IOProcでの受信・共有メモリへの publish、
      clang++でビルド確認)
- [x] SwiftUI アプリ雛形 (128ch レベルメーターグリッド、共有メモリ読み出し)
- [x] SSDBridge (Scene.hラップ、SPEAKER Channel→World座標、SceneKit軸変換)
- [x] SceneKitでのスピーカー3D表示 + レベルに応じた発光・拡大
- [x] `swift build` / `make` (HALPlugin) の両方でビルド確認済み

### 未実装・残課題
- [ ] **128ch化**: `HALPlugin/src/VirtualAudioDevicePlugin.cpp` の
      `kChannelCount` を 16→128 に上げ、`AudioStreamBasicDescription` と
      リングバッファサイズを合わせて再検証する
      (バッファサイズが大きくなるためIOProc内メモリコピー量も要確認)。
- [ ] **実機インストール手順の整備**: `.driver` バンドルを
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

## ビルド方法

```bash
# HAL Plugin (コンパイル確認のみ。インストール手順は上記ロードマップ参照)
cd HALPlugin && make

# SwiftUI アプリ
cd VisualizerApp && swift build
# 実行: swift run VisualizerApp
```

## 参照

- SSD フォーマット仕様: `spatial-audio-kit-and-ssd-v4/ssd/docs/ssd-format-ai-spec.md`
- リファレンス実装: `spatial-audio-kit-and-ssd-v4/ssd/include/ssd/Scene.h`
  (このリポジトリの `VisualizerApp/Sources/SSDBridge/include/ssd/Scene.h` に
  コピーして vendoring。将来アップデートする際は手動同期が必要)
