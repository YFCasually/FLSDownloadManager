import SwiftUI
import FLSDownloadManager

/// 下载组件的 SwiftUI 示例页面，展示单任务、进度和缓存清理入口。
struct FLSDownloadManagerDemoView: View {
    @StateObject private var manager = FLSDownloadManager()
    @State private var urlText = "https://speed.hetzner.de/100MB.bin"

    var body: some View {
        NavigationStack {
            List {
                Section("单文件") {
                    TextField("下载地址", text: $urlText)
                        .textInputAutocapitalization(.never)
                    Button("开始下载") {
                        guard let url = URL(string: urlText) else { return }
                        manager.enqueue(FLSDownloadRequest(url: url))
                    }
                }
                Section("任务") {
                    ForEach(manager.tasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(task.request.url.lastPathComponent)
                            ProgressView(value: task.progress.fractionCompleted)
                            HStack {
                                Text(task.state.rawValue)
                                Spacer()
                                Text("\(Int(task.progress.fractionCompleted * 100))%")
                            }
                            .font(.caption)
                        }
                    }
                }
                Section("缓存") {
                    Button("清理全部缓存") { manager.clearAllCache() }
                    Text("缓存大小：\(manager.cacheSize()) bytes")
                }
            }
            .navigationTitle("FLSDownloadManager")
        }
    }
}
