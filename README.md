# camtune

ウェブカメラ映像をリアルタイムに補正する macOS ネイティブアプリ (MVP)。

- **明度 / コントラスト / 彩度**
- **色温度 / ティント** (ホワイトバランス)
- **ノイズリダクション** (強さ・シャープネス)
- 補正 ON/OFF トグルで前後比較
- プリセット保存 (最大 4 件、`UserDefaults` 永続化)

> 仮想カメラ出力 (Zoom/Teams 連携) と AI 補正 (ローライト・自動 WB・美肌) は Phase 2 / Phase 3 で追加予定。

## 必要環境

- macOS 13 (Ventura) 以降
- Xcode Command Line Tools (`xcode-select --install`)
- Apple Silicon / Intel いずれも可

## ビルドと起動

```bash
./build.sh run        # ビルドして起動
./build.sh            # ビルドのみ
./build.sh debug      # 高速コンパイル (デバッグビルド)
./build.sh clean      # 成果物削除
```

`camtune.app` がリポジトリ直下に生成されます。`open camtune.app` で起動。

初回起動時にカメラへのアクセス許可ダイアログが出ます。許可してください。
うまく権限ダイアログが出ない / 拒否されてしまった場合は次のいずれかで解決します:

```bash
# TCC のカメラ判断をリセット (このアプリ単体)
tccutil reset Camera com.local.camtune

# 全アプリのカメラ判断をリセット
tccutil reset Camera
```

その後、ターミナルからではなく Finder で `camtune.app` をダブルクリックして起動するとダイアログが安定して出ます。

## ディレクトリ構成

```
camtune/
├── Sources/camtune/
│   ├── camtuneApp.swift              # @main, WindowGroup
│   ├── Camera/
│   │   ├── CameraManager.swift       # AVCaptureSession セットアップ / フレーム供給
│   │   └── CameraPreviewView.swift   # MTKView + CoreImage 描画
│   ├── Processing/
│   │   ├── FilterPipeline.swift      # CIFilter チェーン
│   │   └── FilterSettings.swift      # @Published パラメータ
│   └── UI/
│       ├── ContentView.swift         # ルートレイアウト
│       ├── ControlPanel.swift        # スライダー群
│       └── PresetStore.swift         # プリセット永続化
├── Resources/
│   ├── Info.plist                    # NSCameraUsageDescription 等
│   └── camtune.entitlements          # camera entitlement
├── build.sh                          # swiftc + bundle 化スクリプト
└── README.md
```

## アーキテクチャ概要

```
AVCaptureDevice ──▶ AVCaptureSession ──▶ VideoDataOutput delegate
                                                │ (videoQueue, BGRA)
                                                ▼
                                          FilterPipeline
                                       (CIFilter チェーン)
                                                │
                                                ▼  PassthroughSubject<CIImage>
                                          CameraPreviewView
                                          (MTKView + CIContext)
```

- `FilterPipeline` は `FilterSettings` のスナップショットをフレーム毎に取得して適用 (UI スレッドとの競合を回避)。
- 全 `CIFilter` インスタンスは使い回し。中立値のフィルタはスキップ。
- 描画は `MTKView.draw()` を Subject 受信時に明示呼び出し (isPaused = true)。

## Phase 2 / 3 への布石

- `FilterPipeline.process(_:)` の末尾に Vision (`VNDetectFaceRectanglesRequest`) ベースの顔領域スムージングや、ローライト補正用フィルタ (`CIExposureAdjust` + トーンカーブ) を差し込むだけで AI 補正を追加できる。
- 仮想カメラ出力は CMIOExtension をターゲットに追加し、`FilterPipeline` の出力 `CIImage` を `CMSampleBuffer` に変換して Extension 側に渡す I/O 層を作る。Apple Developer Program 登録と Developer ID 署名が必要。
