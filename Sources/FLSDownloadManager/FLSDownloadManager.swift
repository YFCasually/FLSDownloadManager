import Foundation
import Combine
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 基于系统 URLSession 的下载组件。
///
/// 组件提供单文件和批量下载、后台任务恢复、暂停续传、缓存管理、进度发布以及
/// 可选的文件大小和 SHA-256 校验。组件本身不包含业务字段、页面逻辑或 Vograin 类型。
public struct FLSDownloadConfiguration: Sendable {
    public var maximumConcurrentDownloads: Int
    public var sessionIdentifier: String
    public var allowsCellularAccess: Bool
    public var waitsForConnectivity: Bool
    public var cacheDirectoryName: String
    public var automaticallyRestoresTasks: Bool

    public init(
        maximumConcurrentDownloads: Int = 3,
        sessionIdentifier: String = "com.yfcasually.flsdownloadmanager.background",
        allowsCellularAccess: Bool = true,
        waitsForConnectivity: Bool = true,
        cacheDirectoryName: String = "FLSDownloads",
        automaticallyRestoresTasks: Bool = true
    ) {
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
        self.sessionIdentifier = sessionIdentifier
        self.allowsCellularAccess = allowsCellularAccess
        self.waitsForConnectivity = waitsForConnectivity
        self.cacheDirectoryName = cacheDirectoryName
        self.automaticallyRestoresTasks = automaticallyRestoresTasks
    }
}

/// 描述一个待下载资源及其校验要求。
public struct FLSDownloadRequest: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let url: URL
    public let cacheKey: String
    public let headers: [String: String]
    public let expectedSHA256: String?
    public let expectedContentLength: Int64?
    public let priority: Float
    public let allowsCellularAccess: Bool?

    public init(
        id: String = UUID().uuidString,
        url: URL,
        cacheKey: String? = nil,
        headers: [String: String] = [:],
        expectedSHA256: String? = nil,
        expectedContentLength: Int64? = nil,
        priority: Float = URLSessionTask.defaultPriority,
        allowsCellularAccess: Bool? = nil
    ) {
        self.id = id
        self.url = url
        self.cacheKey = cacheKey ?? url.absoluteString
        self.headers = headers
        self.expectedSHA256 = expectedSHA256
        self.expectedContentLength = expectedContentLength
        self.priority = min(max(priority, 0), 1)
        self.allowsCellularAccess = allowsCellularAccess
    }
}

/// 下载任务的生命周期状态。
public enum FLSDownloadState: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

/// 单个下载任务的进度快照。
public struct FLSDownloadProgress: Equatable, Sendable, Codable {
    public let fractionCompleted: Double
    public let bytesWritten: Int64
    public let totalBytesExpected: Int64?
    public let bytesPerSecond: Double
    public let estimatedTimeRemaining: TimeInterval?

    public init(
        fractionCompleted: Double = 0,
        bytesWritten: Int64 = 0,
        totalBytesExpected: Int64? = nil,
        bytesPerSecond: Double = 0,
        estimatedTimeRemaining: TimeInterval? = nil
    ) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.bytesWritten = bytesWritten
        self.totalBytesExpected = totalBytesExpected
        self.bytesPerSecond = bytesPerSecond
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
}

/// 下载任务的持久化状态和运行时结果。
public struct FLSDownloadTask: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let request: FLSDownloadRequest
    public var state: FLSDownloadState
    public var progress: FLSDownloadProgress
    public var fileURL: URL?
    public var errorDescription: String?
    public var batchID: String?

    public init(
        id: String,
        request: FLSDownloadRequest,
        state: FLSDownloadState = .queued,
        progress: FLSDownloadProgress = .init(),
        fileURL: URL? = nil,
        errorDescription: String? = nil,
        batchID: String? = nil
    ) {
        self.id = id
        self.request = request
        self.state = state
        self.progress = progress
        self.fileURL = fileURL
        self.errorDescription = errorDescription
        self.batchID = batchID
    }
}

/// 一组下载任务及其汇总进度。
public struct FLSDownloadBatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskIDs: [String]
    public var progress: FLSDownloadProgress

    public init(id: String, taskIDs: [String], progress: FLSDownloadProgress = .init()) {
        self.id = id
        self.taskIDs = taskIDs
        self.progress = progress
    }
}

/// 下载完成后的统一结果。
public struct FLSDownloadResult: Sendable {
    public let taskID: String
    public let fileURL: URL
    public let fromCache: Bool

    public init(taskID: String, fileURL: URL, fromCache: Bool) {
        self.taskID = taskID
        self.fileURL = fileURL
        self.fromCache = fromCache
    }
}

/// 下载组件对外暴露的错误类型。
public enum FLSDownloadError: Error, LocalizedError, Sendable, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case cancelled
    case missingFile
    case checksumMismatch
    case contentLengthMismatch(expected: Int64, actual: Int64)
    case taskNotFound
    case invalidResumeData
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The download response is invalid."
        case .httpStatus(let status): "The server returned HTTP status \(status)."
        case .cancelled: "The download was cancelled."
        case .missingFile: "The downloaded file is missing."
        case .checksumMismatch: "The downloaded file checksum does not match."
        case .contentLengthMismatch(let expected, let actual): "Expected \(expected) bytes but received \(actual)."
        case .taskNotFound: "The download task was not found."
        case .invalidResumeData: "The saved resume data is invalid."
        case .failed(let message): message
        }
    }
}

/// 下载文件、续传数据和任务元数据的本地缓存目录管理器。
///
/// 默认目录位于系统 Caches 目录，缓存可以随时清理，业务层不应把它当作永久存储。
public final class FLSDownloadCache: @unchecked Sendable {
    public let rootURL: URL

    /// 创建缓存目录；传入 rootURL 主要用于测试或宿主应用自定义目录。
    public init(rootURL: URL? = nil, directoryName: String = "FLSDownloads") {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.rootURL = caches.appendingPathComponent(directoryName, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resumeDataURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
    }

    public var filesURL: URL { rootURL.appendingPathComponent("Files", isDirectory: true) }
    public var resumeDataURL: URL { rootURL.appendingPathComponent("ResumeData", isDirectory: true) }
    public var temporaryURL: URL { rootURL.appendingPathComponent("Temporary", isDirectory: true) }
    public var metadataURL: URL { rootURL.appendingPathComponent("Metadata", isDirectory: true) }

    /// 返回指定请求最终文件的缓存位置。
    public func fileURL(for request: FLSDownloadRequest) -> URL {
        filesURL.appendingPathComponent(Self.safeName(request.cacheKey))
    }

    /// 返回指定任务续传数据的保存位置。
    public func resumeDataURL(for taskID: String) -> URL {
        resumeDataURL.appendingPathComponent(Self.safeName(taskID)).appendingPathExtension("resume")
    }

    /// 返回指定任务元数据的保存位置。
    public func metadataURL(for taskID: String) -> URL {
        metadataURL.appendingPathComponent(Self.safeName(taskID)).appendingPathExtension("json")
    }

    /// 清除文件、续传数据和元数据，并重新创建目录结构。
    public func clearAllCache() throws {
        try FileManager.default.removeItem(at: rootURL)
        self.initDirectories()
    }

    /// 返回下载缓存目录及其子目录中的文件总大小。
    public func cacheSize() -> Int64 {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func initDirectories() {
        try? FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resumeDataURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
    }

    private static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let name = String(cleaned)
        return String(name.prefix(180))
    }
}

public final class FLSDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// 所有任务的可观察快照，适合直接绑定 SwiftUI 列表或进度视图。
    @Published public private(set) var tasks: [FLSDownloadTask] = []
    /// 所有批量任务的可观察快照，进度按子任务字节数汇总。
    @Published public private(set) var batches: [FLSDownloadBatch] = []

    public let configuration: FLSDownloadConfiguration
    public let cache: FLSDownloadCache

    private let stateQueue = DispatchQueue(label: "com.yfcasually.flsdownloadmanager.state")
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: self.configuration.sessionIdentifier)
        configuration.httpMaximumConnectionsPerHost = self.configuration.maximumConcurrentDownloads
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.allowsCellularAccess = self.configuration.allowsCellularAccess
        configuration.waitsForConnectivity = self.configuration.waitsForConnectivity
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var runningTasks: [Int: String] = [:]
    private var records: [String: FLSDownloadTask] = [:]
    private var batchRecords: [String: FLSDownloadBatch] = [:]
    private var resumeData: [String: Data] = [:]
    private var startedAt: [String: Date] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    /// 创建下载管理器，并按配置恢复已经交给系统管理的后台任务。
    public init(configuration: FLSDownloadConfiguration = .init(), cache: FLSDownloadCache? = nil) {
        self.configuration = configuration
        self.cache = cache ?? FLSDownloadCache(directoryName: configuration.cacheDirectoryName)
        super.init()
        loadPersistedTasks()
        if configuration.automaticallyRestoresTasks { restoreBackgroundTasks() }
    }

    @discardableResult
    /// 加入单个下载任务；如果校验通过的缓存已存在，则直接发布完成状态。
    public func enqueue(_ request: FLSDownloadRequest, batchID: String? = nil) -> String {
        stateQueue.sync {
            if let cached = cachedResult(for: request) {
                records[request.id] = FLSDownloadTask(id: request.id, request: request, state: .completed, progress: .init(fractionCompleted: 1, bytesWritten: fileSize(cached), totalBytesExpected: fileSize(cached)), fileURL: cached, batchID: batchID)
            } else {
                records[request.id] = FLSDownloadTask(id: request.id, request: request, batchID: batchID)
            }
            save(record: records[request.id]!)
            publish()
            scheduleNext()
        }
        return request.id
    }

    @discardableResult
    /// 加入一组下载任务，并返回批量任务 ID。
    public func enqueueBatch(_ requests: [FLSDownloadRequest], batchID: String = UUID().uuidString) -> String {
        let ids = requests.map { enqueue($0, batchID: batchID) }
        stateQueue.sync {
            batchRecords[batchID] = FLSDownloadBatch(id: batchID, taskIDs: ids)
            publish()
        }
        return batchID
    }

    /// 读取指定任务当前的状态快照。
    public func task(for id: String) -> FLSDownloadTask? { stateQueue.sync { records[id] } }

    /// 暂停下载并保存系统提供的续传数据。
    public func pause(taskID: String) {
        stateQueue.async {
            guard let identifier = self.runningTasks.first(where: { $0.value == taskID })?.key else { return }
            self.session.getAllTasks { tasks in
                guard let downloadTask = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first(where: { $0.taskIdentifier == identifier }) else { return }
                downloadTask.cancel(byProducingResumeData: { data in
                    self.stateQueue.async {
                        if let data { self.resumeData[taskID] = data; try? data.write(to: self.cache.resumeDataURL(for: taskID), options: .atomic) }
                        self.runningTasks.removeValue(forKey: identifier)
                        self.updateState(id: taskID, state: .paused)
                        self.scheduleNext()
                    }
                })
            }
        }
    }

    /// 恢复处于暂停或失败状态的任务。
    public func resume(taskID: String) {
        stateQueue.async {
            guard var record = self.records[taskID], record.state == .paused || record.state == .failed else { return }
            record.state = .queued
            record.errorDescription = nil
            self.records[taskID] = record
            self.save(record: record)
            self.publish()
            self.scheduleNext()
        }
    }

    /// 取消任务并删除该任务保存的续传数据。
    public func cancel(taskID: String) {
        stateQueue.async {
            if let identifier = self.runningTasks.first(where: { $0.value == taskID })?.key {
                self.session.getAllTasks { tasks in tasks.first(where: { $0.taskIdentifier == identifier })?.cancel() }
            }
            self.resumeData.removeValue(forKey: taskID)
            try? FileManager.default.removeItem(at: self.cache.resumeDataURL(for: taskID))
            self.updateState(id: taskID, state: .cancelled)
            self.scheduleNext()
        }
    }

    /// 将任务重置为排队状态并重新开始下载。
    public func retry(taskID: String) {
        stateQueue.async {
            guard var record = self.records[taskID] else { return }
            record.state = .queued
            record.progress = .init()
            record.errorDescription = nil
            self.records[taskID] = record
            self.save(record: record)
            self.publish()
            self.scheduleNext()
        }
    }

    /// 清除全部下载缓存。
    public func clearAllCache() { stateQueue.async { try? self.cache.clearAllCache() } }
    /// 清除已完成任务及其文件缓存。
    public func clearCompletedCache() {
        stateQueue.async {
            self.records.values.filter { $0.state == .completed }.forEach { task in
                if let fileURL = task.fileURL { try? FileManager.default.removeItem(at: fileURL) }
                self.records.removeValue(forKey: task.id)
            }
            self.publish()
        }
    }
    /// 删除失败任务记录，但保留其他任务。
    public func clearFailedTasks() { stateQueue.async { self.records = self.records.filter { $0.value.state != .failed }; self.publish() } }
    /// 删除任务记录及对应元数据。
    public func remove(taskID: String) { stateQueue.async { self.records.removeValue(forKey: taskID); try? FileManager.default.removeItem(at: self.cache.metadataURL(for: taskID)); self.publish() } }
    /// 删除批量记录及该批次下的任务记录。
    public func remove(batchID: String) { stateQueue.async { self.batchRecords.removeValue(forKey: batchID); self.records = self.records.filter { $0.value.batchID != batchID }; self.publish() } }
    /// 仅删除已完成任务的目标文件，并保留任务状态记录。
    public func removeCachedFile(taskID: String) { stateQueue.async { if let url = self.records[taskID]?.fileURL { try? FileManager.default.removeItem(at: url) }; self.records[taskID]?.fileURL = nil; self.publish() } }
    /// 返回当前缓存目录的文件总大小。
    public func cacheSize() -> Int64 { cache.cacheSize() }

    /// 注册 AppDelegate 在后台 URLSession 完成回调中使用的系统回调。
    public func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) { backgroundCompletionHandler = handler }
    /// 从系统 URLSession 恢复仍在运行的下载任务。
    public func restoreBackgroundTasks() {
        session.getAllTasks { tasks in
            self.stateQueue.async {
                for task in tasks where task.taskDescription != nil {
                    self.runningTasks[task.taskIdentifier] = task.taskDescription!
                }
                self.scheduleNext()
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundCompletionHandler?(); self.backgroundCompletionHandler = nil }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        stateQueue.async {
            guard let id = self.runningTasks[downloadTask.taskIdentifier], var record = self.records[id] else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : record.request.expectedContentLength
            let now = Date()
            let elapsed = max(now.timeIntervalSince(self.startedAt[id] ?? now), 0.001)
            let speed = Double(totalBytesWritten) / elapsed
            let fraction = total.map { Double(totalBytesWritten) / Double(max($0, 1)) } ?? 0
            let remaining = total.flatMap { speed > 0 ? TimeInterval(max($0 - totalBytesWritten, 0)) / speed : nil }
            record.state = .downloading
            record.progress = FLSDownloadProgress(fractionCompleted: fraction, bytesWritten: totalBytesWritten, totalBytesExpected: total, bytesPerSecond: speed, estimatedTimeRemaining: remaining)
            self.records[id] = record
            self.save(record: record)
            self.publish()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        stateQueue.async {
            guard let id = self.runningTasks[downloadTask.taskIdentifier], let record = self.records[id] else { return }
            do {
                let response = downloadTask.response as? HTTPURLResponse
                guard let status = response?.statusCode, (200...299).contains(status) else { throw FLSDownloadError.httpStatus((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0) }
                let destination = self.cache.fileURL(for: record.request)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                let size = self.fileSize(destination)
                if let expected = record.request.expectedContentLength, expected != size { throw FLSDownloadError.contentLengthMismatch(expected: expected, actual: size) }
                if let expected = record.request.expectedSHA256, Self.sha256(of: destination) != expected.lowercased() { throw FLSDownloadError.checksumMismatch }
                var updated = record
                updated.state = .completed
                updated.fileURL = destination
                updated.progress = FLSDownloadProgress(fractionCompleted: 1, bytesWritten: size, totalBytesExpected: size, bytesPerSecond: record.progress.bytesPerSecond)
                self.records[id] = updated
                self.save(record: updated)
                try? FileManager.default.removeItem(at: self.cache.resumeDataURL(for: id))
                self.runningTasks.removeValue(forKey: downloadTask.taskIdentifier)
                self.publish()
                self.scheduleNext()
            } catch {
                self.fail(id: id, error: error)
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateQueue.async {
            guard let id = self.runningTasks[task.taskIdentifier] else { return }
            self.runningTasks.removeValue(forKey: task.taskIdentifier)
            if let error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorCancelled { return }
                self.fail(id: id, error: error)
            } else if self.records[id]?.state != .completed {
                self.fail(id: id, error: FLSDownloadError.invalidResponse)
            }
            self.scheduleNext()
        }
    }

    private func scheduleNext() {
        while runningTasks.count < configuration.maximumConcurrentDownloads,
              let next = records.values.first(where: { $0.state == .queued }) {
            start(next)
        }
        publish()
    }

    private func start(_ record: FLSDownloadTask) {
        var request = URLRequest(url: record.request.url)
        request.allHTTPHeaderFields = record.request.headers
        request.allowsCellularAccess = record.request.allowsCellularAccess ?? configuration.allowsCellularAccess
        let downloadTask: URLSessionDownloadTask
        if let data = resumeData[record.id] ?? (try? Data(contentsOf: cache.resumeDataURL(for: record.id))) {
            downloadTask = session.downloadTask(withResumeData: data)
        } else {
            downloadTask = session.downloadTask(with: request)
        }
        downloadTask.taskDescription = record.id
        downloadTask.priority = record.request.priority
        runningTasks[downloadTask.taskIdentifier] = record.id
        startedAt[record.id] = Date()
        updateState(id: record.id, state: .downloading)
        downloadTask.resume()
    }

    private func updateState(id: String, state: FLSDownloadState) {
        guard var record = records[id] else { return }
        record.state = state
        records[id] = record
        save(record: record)
        publish()
    }

    private func fail(id: String, error: Error) {
        guard var record = records[id] else { return }
        record.state = .failed
        record.errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        records[id] = record
        save(record: record)
        publish()
    }

    private func cachedResult(for request: FLSDownloadRequest) -> URL? {
        let url = cache.fileURL(for: request)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let expected = request.expectedSHA256, Self.sha256(of: url) != expected.lowercased() { try? FileManager.default.removeItem(at: url); return nil }
        if let expected = request.expectedContentLength, fileSize(url) != expected { try? FileManager.default.removeItem(at: url); return nil }
        return url
    }

    private func fileSize(_ url: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }

    private func save(record: FLSDownloadTask) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: cache.metadataURL(for: record.id), options: .atomic)
    }

    private func loadPersistedTasks() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: cache.metadataURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(FLSDownloadTask.self, from: data) { records[record.id] = record }
        }
        publish()
    }

    private func publish() {
        let snapshot = Array(records.values).sorted { $0.id < $1.id }
        let batchSnapshot = batchRecords.values.map { batch in
            var updated = batch
            let children = batch.taskIDs.compactMap { records[$0] }
            let knownTotal = children.compactMap { $0.progress.totalBytesExpected }.reduce(0, +)
            let completed = children.reduce(0.0) { partial, task in
                if knownTotal > 0, task.progress.totalBytesExpected != nil { return partial + Double(task.progress.bytesWritten) / Double(knownTotal) }
                return partial + task.progress.fractionCompleted / Double(max(children.count, 1))
            }
            updated.progress = FLSDownloadProgress(fractionCompleted: completed, bytesWritten: children.reduce(0) { $0 + $1.progress.bytesWritten }, totalBytesExpected: knownTotal > 0 ? knownTotal : nil, bytesPerSecond: children.reduce(0) { $0 + $1.progress.bytesPerSecond })
            return updated
        }
        DispatchQueue.main.async { self.tasks = snapshot; self.batches = batchSnapshot.sorted { $0.id < $1.id } }
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}
