import AppKit
import Foundation
import LivePhotoEngine
import SwiftUI
import UniformTypeIdentifiers

enum JobState: Equatable {
    case queued, converting, exported, imported, failed, cancelled
}

struct ConversionJob: Identifiable {
    let id = UUID()
    var sourceURL: URL
    var byteCount: Int64
    var source: MotionPhotoSource?
    var state: JobState = .queued
    var progress: Double = 0
    var detail = "Ready to convert"
    var result: ConversionResult?
    var importError: String?

    var resourceURLs: [URL] { source?.resourceURLs ?? [sourceURL] }
    var notes: [String] {
        var seen = Set<String>()
        return ((source?.warnings ?? []) + (result?.warnings ?? [])).filter { seen.insert($0).inserted }
    }
}

struct PreviewTarget: Identifiable {
    let id = UUID()
    let title: String
    let result: ConversionResult
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var jobs: [ConversionJob] = []
    @Published private(set) var outputDirectory: URL?
    @Published var includeAudio = true
    @Published var trimToThreeSeconds = true
    @Published var importToPhotos = false
    @Published private(set) var outputFormat: MotionPhotoOutputFormat = .appleLivePhoto
    @Published private(set) var isConverting = false
    @Published private(set) var isScanning = false
    @Published private(set) var scanStatus = "Finding files…"
    @Published private(set) var importingID: UUID?
    @Published private(set) var cancellationRequested = false
    @Published private(set) var batchFinished = 0
    @Published private(set) var batchTotal = 0
    @Published private(set) var currentProgress: Double = 0
    @Published private(set) var lastBatchSummary: String?
    @Published var notice: String?
    @Published var preview: PreviewTarget?

    var onBecomingIdle: (() -> Void)?

    private var conversionTask: Task<Void, Never>?
    private var pendingInputs: [URL] = []
    private var securityScopes: [URL: Bool] = [:]
    private var activeRunID: UUID?
    private var outputWasChosenByUser = false
    private var knownByteCounts: [String: Int64] = [:]
    private let maxQueuedPhotos = 2_000
    private let maxInputResources = 4_000

    var isBusy: Bool { isConverting || isScanning || importingID != nil }
    var pendingCount: Int { jobs.filter { $0.source != nil && ($0.state == .queued || $0.state == .cancelled) }.count }
    var failedCount: Int { jobs.filter { $0.state == .failed }.count }
    var retryableFailureCount: Int { jobs.filter { $0.state == .failed && $0.source != nil }.count }
    var detectionFailureCount: Int { jobs.filter { $0.source == nil && $0.result == nil }.count }
    var canRequeueForDestination: Bool {
        jobs.contains { $0.source != nil && $0.result != nil && $0.result?.outputFormat != outputFormat }
    }
    var exportedCount: Int { jobs.filter { $0.result != nil }.count }
    var importedCount: Int { jobs.filter { $0.state == .imported }.count }
    var batchProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1, (Double(batchFinished) + currentProgress) / Double(batchTotal))
    }

    func chooseFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Motion Photos or Live Photos"
        panel.message = "Choose Samsung or Google originals, or the image and MOV from an Apple Live Photo. Formats and matching pairs are detected automatically."
        panel.prompt = "Add Photos"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["jpg", "jpeg", "heic", "heif", "avif", "mov", "mp4"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { enqueueURLs(panel.urls) }
    }

    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Add a folder of motion photos"
        panel.message = "Images and paired videos in subfolders are included. Apple Live Photo pairs are matched automatically. Hidden files, packages, and symbolic links are skipped."
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { enqueueURLs(panel.urls) }
    }

    func chooseOutputDirectory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an export folder"
        panel.message = "Each converted photo gets its own folder. Apple exports contain JPEG + MOV; Google and Samsung exports contain a JPEG with embedded motion."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            retainSecurityScope(for: url)
            outputDirectory = url
        }
    }

    func selectOutputFormat(_ format: MotionPhotoOutputFormat) {
        guard !isBusy else { return }
        outputWasChosenByUser = true
        outputFormat = format
    }

    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isConverting, importingID == nil else { return false }
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        // Resolve an entire drop before detection so a two-file Live Photo is
        // considered together and large drops do not trigger one scan per file.
        Task { [weak self] in
            let urls = await withTaskGroup(of: URL?.self) { group in
                for provider in matching {
                    group.addTask { await Self.fileURL(from: provider) }
                }
                var urls: [URL] = []
                for await url in group { if let url { urls.append(url) } }
                return urls
            }
            guard let self else { return }
            if !urls.isEmpty { self.enqueueURLs(urls) }
            if urls.count != matching.count {
                self.notice = "Some dropped items could not be opened. Export their original files to Finder, then add them again."
            }
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let value = item as? NSURL { url = value as URL }
                else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                else { url = nil }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    func enqueueURLs(_ urls: [URL]) {
        guard !isConverting, importingID == nil else {
            notice = "Wait for the current conversion to finish before adding more photos."
            return
        }
        let inputs = urls.filter(\.isFileURL)
        guard !inputs.isEmpty else { return }
        for url in inputs { retainSecurityScope(for: url) }
        pendingInputs.append(contentsOf: inputs)
        guard !isScanning else { return }
        isScanning = true
        lastBatchSummary = nil

        Task { [weak self] in
            guard let self else { return }
            var messages: [String] = []
            while !self.pendingInputs.isEmpty {
                let currentInputs = self.pendingInputs
                self.pendingInputs.removeAll()
                self.scanStatus = "Finding images and videos…"
                let existingURLs = self.jobs.flatMap(\.resourceURLs)
                let knownPaths = Set(existingURLs.map { $0.standardizedFileURL.path })
                let remaining = max(0, self.maxInputResources - knownPaths.count)
                let scan = await Task.detached(priority: .userInitiated) {
                    PhotoFileScanner.scan(currentInputs, excluding: knownPaths, limit: remaining)
                }.value
                messages.append(contentsOf: scan.warnings)
                for file in scan.files { self.knownByteCounts[file.url.standardizedFileURL.path] = file.byteCount }
                var seen = Set<String>()
                let candidates = (existingURLs + scan.files.map(\.url)).filter {
                    seen.insert($0.standardizedFileURL.path).inserted
                }
                self.scanStatus = "Detecting formats and matching Live Photos…"
                let cachedSizes = self.knownByteCounts
                let batch = await Task.detached(priority: .userInitiated) {
                    let detections = await MotionSourceDetector.detect(urls: candidates)
                    var sizes = cachedSizes
                    for detection in detections {
                        for url in detection.source?.resourceURLs ?? [detection.inputURL] {
                            let path = url.standardizedFileURL.path
                            if sizes[path] == nil {
                                sizes[path] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                            }
                        }
                    }
                    return DetectionBatch(results: detections, byteCounts: sizes)
                }.value
                self.knownByteCounts = batch.byteCounts
                if self.mergeDetections(batch.results) {
                    messages.append("The queue holds up to 2,000 photos. Clear completed items before adding more.")
                }
                self.chooseAutomaticDestination()
            }
            self.isScanning = false
            if !messages.isEmpty { self.notice = Array(Set(messages)).sorted().joined(separator: "\n") }
            self.notifyIfIdle()
        }
    }

    func startConversion() {
        guard !isBusy, pendingCount > 0 else { return }
        if outputDirectory == nil { chooseOutputDirectory() }
        guard let destination = outputDirectory else { return }

        let ids = jobs.filter { $0.source != nil && ($0.state == .queued || $0.state == .cancelled) }.map(\.id)
        let options = ConversionOptions(includeAudio: includeAudio, trimToThreeSeconds: trimToThreeSeconds, outputFormat: outputFormat)
        let shouldImport = importToPhotos && outputFormat == .appleLivePhoto
        let runID = UUID()
        activeRunID = runID
        isConverting = true
        cancellationRequested = false
        batchFinished = 0
        batchTotal = ids.count
        currentProgress = 0
        lastBatchSummary = nil

        conversionTask = Task { [weak self] in
            guard let self else { return }
            var successes = 0
            var failures = 0
            var importFailures = 0
            for id in ids {
                if Task.isCancelled { break }
                guard let index = self.index(for: id), let source = self.jobs[index].source else { continue }
                self.jobs[index].state = .converting
                self.jobs[index].progress = 0
                self.jobs[index].detail = "Reading \(source.format.displayName)…"
                self.jobs[index].importError = nil
                self.currentProgress = 0

                let worker = Task.detached(priority: .userInitiated) { [weak self] in
                    try await MotionPhotoConverter.convert(
                        source: source,
                        destinationDirectory: destination,
                        options: options
                    ) { progress, message in
                        Task { @MainActor [weak self] in
                            self?.updateProgress(id: id, runID: runID, progress: progress, message: message)
                        }
                    }
                }

                do {
                    let result = try await withTaskCancellationHandler(operation: {
                        try await worker.value
                    }, onCancel: {
                        worker.cancel()
                    })
                    guard let current = self.index(for: id) else { continue }
                    self.jobs[current].result = result
                    self.jobs[current].progress = 1
                    self.jobs[current].state = .exported
                    self.jobs[current].detail = "\(result.outputFormat.displayName) exported"
                    successes += 1

                    if shouldImport && result.supportsPhotosImport {
                        if Task.isCancelled {
                            self.jobs[current].importError = "Photos import was skipped when conversion stopped. Your export is ready."
                        } else {
                            self.jobs[current].detail = "Adding to Photos…"
                            do {
                                try await PhotosImporter.importPair(result)
                                self.jobs[current].state = .imported
                                self.jobs[current].detail = "Exported and added to Photos"
                            } catch {
                                self.jobs[current].importError = error.localizedDescription
                                self.jobs[current].detail = "Exported · Photos import needs attention"
                                importFailures += 1
                            }
                        }
                    }
                } catch {
                    if let current = self.index(for: id) {
                        if Task.isCancelled || error is CancellationError {
                            self.jobs[current].state = .cancelled
                            self.jobs[current].detail = "Stopped · ready to try again"
                        } else {
                            self.jobs[current].state = .failed
                            self.jobs[current].detail = error.localizedDescription
                            failures += 1
                        }
                    }
                }
                self.batchFinished += 1
                self.currentProgress = 0
            }

            let stopped = Task.isCancelled
            self.activeRunID = nil
            self.isConverting = false
            self.cancellationRequested = false
            self.conversionTask = nil
            let headline = stopped ? "Stopped. " : "Finished. "
            var summary = headline + "\(successes) \(successes == 1 ? "photo" : "photos") exported"
            if failures > 0 { summary += "; \(failures) could not be converted" }
            if importFailures > 0 { summary += "; \(importFailures) need Photos import retried" }
            self.lastBatchSummary = summary + "."
            self.notifyIfIdle()
        }
    }

    func cancelConversion() {
        guard isConverting else { return }
        cancellationRequested = true
        conversionTask?.cancel()
    }

    func retryFailed() {
        guard !isBusy else { return }
        for index in jobs.indices where jobs[index].state == .failed && jobs[index].source != nil {
            jobs[index].state = .queued
            jobs[index].detail = "Ready to try again"
            jobs[index].progress = 0
        }
        startConversion()
    }

    func retry(_ id: UUID) {
        guard !isBusy, let index = index(for: id), jobs[index].result == nil else { return }
        guard jobs[index].source != nil else {
            enqueueURLs([jobs[index].sourceURL])
            return
        }
        jobs[index].state = .queued
        jobs[index].detail = "Ready to try again"
        jobs[index].progress = 0
    }

    func importExported(_ id: UUID) {
        guard !isBusy, let index = index(for: id), let result = jobs[index].result,
              result.supportsPhotosImport, jobs[index].state != .imported else { return }
        importingID = id
        jobs[index].detail = "Adding to Photos…"
        jobs[index].importError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await PhotosImporter.importPair(result)
                if let current = self.index(for: id) {
                    self.jobs[current].state = .imported
                    self.jobs[current].detail = "Exported and added to Photos"
                }
            } catch {
                if let current = self.index(for: id) {
                    self.jobs[current].importError = error.localizedDescription
                    self.jobs[current].detail = "Exported · Photos import needs attention"
                }
            }
            self.importingID = nil
            self.notifyIfIdle()
        }
    }

    func recheckUnrecognized() {
        guard !isBusy else { return }
        enqueueURLs(jobs.filter { $0.source == nil }.map(\.sourceURL))
    }

    func requeueForDestination(_ id: UUID) {
        guard !isBusy, let index = index(for: id), jobs[index].source != nil, jobs[index].result != nil else { return }
        jobs[index].result = nil
        jobs[index].importError = nil
        jobs[index].progress = 0
        jobs[index].state = .queued
        jobs[index].detail = "Ready for \(outputFormat.displayName) · previous export kept"
        lastBatchSummary = nil
    }

    func requeueCompletedForDestination() {
        guard !isBusy else { return }
        let ids = jobs.filter { $0.source != nil && $0.result != nil && $0.result?.outputFormat != outputFormat }.map(\.id)
        for id in ids { requeueForDestination(id) }
    }

    func showPreview(for job: ConversionJob) {
        guard let result = job.result else { return }
        preview = PreviewTarget(title: job.sourceURL.lastPathComponent, result: result)
    }

    func revealExport(for job: ConversionJob) {
        guard let result = job.result else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.directoryURL])
    }

    func revealOutputDirectory() {
        guard let outputDirectory else { return }
        NSWorkspace.shared.open(outputDirectory)
    }

    func remove(_ id: UUID) {
        guard !isBusy else { return }
        jobs.removeAll { $0.id == id }
        lastBatchSummary = nil
        chooseAutomaticDestination()
    }

    func clearCompleted() {
        guard !isBusy else { return }
        jobs.removeAll { $0.result != nil }
        lastBatchSummary = nil
        chooseAutomaticDestination()
    }

    func clearAll() {
        guard !isBusy else { return }
        jobs.removeAll()
        knownByteCounts.removeAll()
        lastBatchSummary = nil
        chooseAutomaticDestination()
        // Clearing the queue removes its previews; retain only the selected destination grant.
        for url in Array(securityScopes.keys) where url != outputDirectory {
            if securityScopes.removeValue(forKey: url) == true { url.stopAccessingSecurityScopedResource() }
        }
    }

    func releaseSecurityScopes() {
        for (url, didStart) in securityScopes where didStart { url.stopAccessingSecurityScopedResource() }
        securityScopes.removeAll()
    }

    private func retainSecurityScope(for url: URL) {
        guard securityScopes[url] != true else { return }
        // A newly selected URL may carry a grant that an earlier URL for the
        // same path did not. Keep its actual instance for the matching stop.
        securityScopes.removeValue(forKey: url)
        securityScopes[url] = url.startAccessingSecurityScopedResource()
    }

    /// Rebuild the queue from one detector batch. Resources belonging to a
    /// resolved pair supersede earlier orphan rows, while completed exports and
    /// conversion failures retain their IDs, results, and useful status.
    @discardableResult
    private func mergeDetections(_ detections: [SourceDetectionResult]) -> Bool {
        let previous = jobs
        let previousOrder = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element.id, $0.offset) })
        var merged: [ConversionJob] = []
        var canonicalPaths = Set<String>()
        var claimedIDs = Set<UUID>()
        let consumedPaths = Set(detections.compactMap(\.source).flatMap(\.resourceURLs).map { $0.standardizedFileURL.path })

        for detection in detections {
            guard let source = detection.source else { continue }
            let imagePath = source.imageURL.standardizedFileURL.path
            guard canonicalPaths.insert(imagePath).inserted else { continue }
            let resourcePaths = Set(source.resourceURLs.map { $0.standardizedFileURL.path })
            let previousJob = previous.first { !claimedIDs.contains($0.id) && $0.sourceURL.standardizedFileURL.path == imagePath }
                ?? previous.first { !claimedIDs.contains($0.id) && $0.source == nil && resourcePaths.contains($0.sourceURL.standardizedFileURL.path) }
            var job = previousJob ?? ConversionJob(sourceURL: source.imageURL, byteCount: 0, source: source)
            let wasUnrecognized = job.source == nil
            job.sourceURL = source.imageURL
            job.source = source
            job.byteCount = source.resourceURLs.reduce(0) { $0 + (knownByteCounts[$1.standardizedFileURL.path] ?? 0) }
            if wasUnrecognized && job.result == nil {
                job.state = .queued
                job.progress = 0
                job.detail = "Ready to convert"
            }
            for url in source.resourceURLs { retainSecurityScope(for: url) }
            claimedIDs.insert(job.id)
            merged.append(job)
        }
        for detection in detections where detection.source == nil {
            let path = detection.inputURL.standardizedFileURL.path
            guard !consumedPaths.contains(path), canonicalPaths.insert(path).inserted else { continue }
            var job = previous.first { $0.sourceURL.standardizedFileURL.path == path }
                ?? ConversionJob(sourceURL: detection.inputURL, byteCount: knownByteCounts[path] ?? 0, source: nil)
            job.source = nil
            if job.result == nil {
                job.state = .failed
                job.progress = 0
                job.detail = detection.errorMessage ?? "This file could not be identified as a motion photo."
            } else {
                job.detail = "Export kept · original source is unavailable"
            }
            merged.append(job)
        }
        // Completed output remains accessible even if the source was removed
        // or a detector intentionally suppressed one of its duplicate inputs.
        for job in previous where job.result != nil && !merged.contains(where: { $0.id == job.id }) {
            if canonicalPaths.insert(job.sourceURL.standardizedFileURL.path).inserted { merged.append(job) }
        }
        merged.sort {
            let left = previousOrder[$0.id] ?? Int.max
            let right = previousOrder[$1.id] ?? Int.max
            if left != right { return left < right }
            return $0.sourceURL.path.localizedStandardCompare($1.sourceURL.path) == .orderedAscending
        }
        let exceededLimit = merged.count > maxQueuedPhotos
        jobs = Array(merged.prefix(maxQueuedPhotos))
        return exceededLimit
    }

    private func chooseAutomaticDestination() {
        guard !outputWasChosenByUser else { return }
        let sources = jobs.compactMap(\.source)
        outputFormat = !sources.isEmpty && sources.allSatisfy { $0.format.outputFormat == .appleLivePhoto }
            ? .googleMotionPhoto : .appleLivePhoto
    }

    private func updateProgress(id: UUID, runID: UUID, progress: Double, message: String) {
        guard activeRunID == runID, let index = index(for: id), jobs[index].state == .converting else { return }
        let value = progress.isFinite ? min(1, max(0, progress)) : 0
        jobs[index].progress = value
        jobs[index].detail = message
        currentProgress = value
    }

    private func index(for id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func notifyIfIdle() {
        guard !isBusy else { return }
        let callback = onBecomingIdle
        onBecomingIdle = nil
        callback?()
    }
}

private struct DetectionBatch: Sendable {
    let results: [SourceDetectionResult]
    let byteCounts: [String: Int64]
}

private struct ScannedPhoto: Sendable {
    let url: URL
    let byteCount: Int64
}

private struct ScanResult: Sendable {
    var files: [ScannedPhoto] = []
    var warnings: [String] = []
}

private enum PhotoFileScanner {
    private static let allowedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "avif", "mov", "mp4"]
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isPackageKey]

    static func scan(_ inputs: [URL], excluding knownPaths: Set<String>, limit: Int) -> ScanResult {
        var result = ScanResult()
        guard limit > 0 else {
            result.warnings = ["The queue holds up to 4,000 image and video resources. Clear completed items before adding more."]
            return result
        }
        var seen = knownPaths
        var skipped = 0
        var unreadable = 0
        var visited = 0
        var reachedLimit = false

        func append(_ url: URL, values: URLResourceValues) {
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { skipped += 1; return }
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { return }
            guard result.files.count < limit else { reachedLimit = true; return }
            result.files.append(ScannedPhoto(url: normalized, byteCount: Int64(values.fileSize ?? 0)))
        }

        for input in inputs {
            if reachedLimit { break }
            guard let values = try? input.resourceValues(forKeys: keys) else { unreadable += 1; continue }
            guard values.isSymbolicLink != true else { skipped += 1; continue }
            if values.isDirectory == true {
                guard values.isPackage != true else { skipped += 1; continue }
                guard let enumerator = FileManager.default.enumerator(
                    at: input,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in unreadable += 1; return true }
                ) else { unreadable += 1; continue }
                for case let file as URL in enumerator {
                    visited += 1
                    if visited > 50_000 {
                        result.warnings.append("Folder scanning stopped after 50,000 entries. Add a smaller folder to include any remaining photos.")
                        reachedLimit = true
                        break
                    }
                    guard let fileValues = try? file.resourceValues(forKeys: keys) else { unreadable += 1; continue }
                    if fileValues.isSymbolicLink == true || fileValues.isPackage == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    append(file, values: fileValues)
                    if reachedLimit { break }
                }
            } else {
                append(input, values: values)
            }
        }
        result.files.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        if result.files.count == limit && reachedLimit {
            result.warnings.append("Up to 4,000 image and video resources can be detected at once. Clear completed items and add any remaining files in another batch.")
        }
        if unreadable > 0 { result.warnings.append("\(unreadable) file or folder \(unreadable == 1 ? "was" : "were") unreadable. Check access permissions and try again.") }
        if result.files.isEmpty && skipped > 0 {
            result.warnings.append("No new supported files were found. Choose original JPEG, HEIC, HEIF, or AVIF motion photos, or the image and MOV from an Apple Live Photo.")
        }
        return result
    }
}
