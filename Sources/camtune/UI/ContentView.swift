import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var settings: FilterSettings
    @StateObject private var presetPreviews = PresetPreviewRenderer()
    @StateObject private var camera: CameraManager
    @StateObject private var extensionManager = ExtensionManager()
    @StateObject private var virtualCamera = VirtualCameraOutput()

    @State private var frameForwardingSubscription: AnyCancellable?

    init() {
        let s = FilterSettings()
        _settings = StateObject(wrappedValue: s)
        _camera = StateObject(wrappedValue: CameraManager(pipeline: FilterPipeline(settings: s)))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("カメラ", selection: Binding(
                        get: { camera.selectedDeviceID ?? "" },
                        set: { id in
                            guard !id.isEmpty else { return }
                            camera.selectDevice(id: id)
                        }
                    )) {
                        ForEach(camera.availableDevices, id: \.uniqueID) { d in
                            Text(d.localizedName).tag(d.uniqueID)
                        }
                    }
                    .frame(maxWidth: 280)
                    Spacer()
                    Text(camera.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)

                CameraPreviewView(manager: camera)
                    .frame(minWidth: 480, minHeight: 360)
                    .background(Color.black)
            }

            VStack(spacing: 0) {
                ControlPanel(settings: settings, presetPreviews: presetPreviews)
                Divider()
                VirtualCameraPanel(manager: extensionManager, output: virtualCamera)
                    .padding(8)
            }
            .frame(minWidth: 320)
        }
        .frame(minWidth: 880, minHeight: 600)
        .task {
            await camera.start()
            extensionManager.refreshStatus()
            // Send processed frames into the virtual camera output.
            frameForwardingSubscription = camera.processedFrames
                .sink { [virtualCamera] image in
                    virtualCamera.sendFrame(image)
                }
            // Feed raw frames into the preset preview renderer so tiles
            // show the user's live face with each preset applied.
            presetPreviews.subscribe(to: camera.rawFrames)
        }
        .onDisappear {
            camera.stop()
            frameForwardingSubscription?.cancel()
        }
    }
}

private struct VirtualCameraPanel: View {
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var output: VirtualCameraOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("仮想カメラ").font(.headline)
                Spacer()
                statusBadge
            }

            if !manager.lastMessage.isEmpty {
                Text(manager.lastMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button(isInstalled ? "更新 / 再インストール" : "インストール") {
                    manager.install()
                }
                .disabled(isBusy)
                if isInstalled {
                    Button("アンインストール") { manager.uninstall() }
                        .disabled(isBusy)
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text(output.statusMessage)
                    .font(.caption)
                Spacer()
                Text("\(output.sentFrameCount) 送信")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Zoom / Teams / Photo Booth で「camtune Virtual Camera」を選ぶと、補正済み映像が見えます")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isInstalled: Bool {
        // True source of truth: sink stream connection. If we can see and write
        // to the extension's CMIO sink, it's definitely installed and running.
        if output.connected { return true }
        if case .installed = manager.status { return true }
        return false
    }

    private var isBusy: Bool {
        switch manager.status {
        case .installing, .uninstalling, .needsApproval: return true
        default: return false
        }
    }

    private var installButtonLabel: String {
        switch manager.status {
        case .installed: return "アンインストール"
        case .installing: return "インストール中…"
        case .uninstalling: return "アンインストール中…"
        case .needsApproval: return "承認待ち"
        case .failed: return "インストール (再試行)"
        default: return "インストール"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(badgeText)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(badgeColor.opacity(0.2))
            .foregroundStyle(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var badgeText: String {
        if output.connected { return "稼働中" }
        switch manager.status {
        case .unknown: return "不明"
        case .notInstalled: return "未インストール"
        case .installing: return "インストール中"
        case .installed: return "インストール済み"
        case .uninstalling: return "削除中"
        case .needsApproval: return "承認待ち"
        case .failed: return "失敗"
        }
    }

    private var badgeColor: Color {
        if output.connected { return .green }
        switch manager.status {
        case .installed: return .green
        case .needsApproval, .installing, .uninstalling: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
