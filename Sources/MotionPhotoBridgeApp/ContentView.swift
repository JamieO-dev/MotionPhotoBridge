import AppKit
import LivePhotoEngine
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    static let bridgeAccent = Color(red: 0.43, green: 0.36, blue: 0.88)
    static let bridgeBlue = Color(red: 0.24, green: 0.55, blue: 0.93)
    static let bridgeSurface = Color(nsColor: .controlBackgroundColor)
}

@MainActor
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 248)
            Divider()
            VStack(spacing: 0) {
                queueHeader
                Divider()
                ZStack {
                    if model.jobs.isEmpty {
                        emptyState
                    } else {
                        queueList
                    }
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.bridgeAccent.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.bridgeAccent, lineWidth: 2))
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: model.acceptDrop)
                Divider()
                footer
            }
        }
        .tint(.bridgeAccent)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.preview) { target in
            ExportPreview(target: target)
        }
        .alert("MotionPhotoBridge", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var sidebar: some View {
        ScrollView {
            sidebarContents
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }

    private var sidebarContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MotionPhotoBridge")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Keep every moment moving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 25)

            VStack(alignment: .leading, spacing: 8) {
                Label("Automatic detection", systemImage: "viewfinder")
                    .font(.system(size: 12, weight: .medium))
                Text("Apple · Google · Samsung")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bridgeAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            sectionLabel("CONVERT TO")
                .padding(.top, 24)
            Picker("Output format", selection: Binding(
                get: { model.outputFormat },
                set: { model.selectOutputFormat($0) }
            )) {
                ForEach(MotionPhotoOutputFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(model.isBusy)
            Text(model.outputFormat.fileDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            sectionLabel("SAVE IN")
                .padding(.top, 22)
            Button(action: model.chooseOutputDirectory) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.bridgeAccent)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.outputDirectory?.lastPathComponent ?? "Choose a folder…")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(model.outputDirectory?.path ?? "One folder per converted photo")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bridgeSurface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .help(model.outputDirectory?.path ?? "Choose where converted photos will be saved")
            .accessibilityLabel("Export folder")
            .accessibilityValue(model.outputDirectory?.path ?? "Not selected")

            sectionLabel("CONVERSION")
                .padding(.top, 25)
            VStack(alignment: .leading, spacing: 15) {
                Toggle("Keep original audio", isOn: $model.includeAudio)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Motion length")
                        .font(.system(size: 12))
                    Picker("Motion length", selection: $model.trimToThreeSeconds) {
                        Text("3 seconds").tag(true)
                        Text("Full clip").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("A short clip is centered on the original photo’s capture time when available.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.outputFormat == .appleLivePhoto {
                    Divider()
                    Toggle("Also add to Photos", isOn: $model.importToPhotos)
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                    Text("Ask for Photos access when you convert. An export is always kept.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(model.isBusy)

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 7) {
                Label("On your Mac. No uploads.", systemImage: "lock.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("JPEG + H.264 video · Standard dynamic range. HDR and gain maps aren’t preserved.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)
    }

    private var queueHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Your Photos")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(model.jobs.isEmpty ? "Convert between Apple, Google, and Samsung." : queueSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Add Photos…", action: model.chooseFiles)
                Button("Add Folder…", action: model.chooseFolder)
            } label: {
                Label("Add", systemImage: "plus")
                    .padding(.horizontal, 3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isBusy)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.bridgeSurface, in: RoundedRectangle(cornerRadius: 8))
            if !model.jobs.isEmpty {
                Menu {
                    Button("Queue Completed for \(model.outputFormat.displayName)", action: model.requeueCompletedForDestination)
                        .disabled(!model.canRequeueForDestination)
                    Button("Recheck Unrecognized Sources", action: model.recheckUnrecognized)
                        .disabled(model.detectionFailureCount == 0)
                    Divider()
                    Button("Clear Completed", action: model.clearCompleted)
                        .disabled(model.exportedCount == 0)
                    Button("Clear Queue", action: model.clearAll)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isBusy)
                .help("Queue options")
                .accessibilityLabel("Queue options")
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 23)
    }

    private var queueSubtitle: String {
        var parts = ["\(model.jobs.count) \(model.jobs.count == 1 ? "photo" : "photos")"]
        if model.exportedCount > 0 { parts.append("\(model.exportedCount) exported") }
        if model.importedCount > 0 { parts.append("\(model.importedCount) in Photos") }
        if model.failedCount > 0 { parts.append("\(model.failedCount) need attention") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.bridgeAccent.opacity(0.035)).frame(width: 124, height: 124)
                Circle().stroke(Color.bridgeAccent.opacity(0.10), lineWidth: 1).frame(width: 104, height: 104)
                BrandMark(size: 72)
            }
            VStack(spacing: 9) {
                Text(isDropTargeted ? "Drop to detect your photos" : "Motion photos, in any direction.")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Drop Apple Live Photos or Samsung and Google Motion Photos.\nWe detect the source. You choose the destination.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            Button(action: model.chooseFiles) {
                Label("Choose Photos…", systemImage: "plus")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy)
            HStack(spacing: 7) {
                formatPill("Apple Live Photos")
                formatPill("Google")
                formatPill("Samsung")
            }
            Label {
                Text("For Apple Live Photos, export unmodified originals from Photos and add the image + MOV. For Samsung and Google, use originals with embedded motion.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: 400)
            .padding(.top, 8)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .padding(18)
        }
    }

    private func formatPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04), in: Capsule())
    }

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                ForEach(model.jobs) { job in
                    QueueRow(job: job, model: model)
                }
            }
            .padding(20)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if model.isConverting {
                VStack(spacing: 7) {
                    HStack {
                        Text(model.cancellationRequested ? "Stopping safely…" : "Converting \(min(model.batchFinished + 1, model.batchTotal)) of \(model.batchTotal)")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(model.cancellationRequested ? "Completed exports will be kept" : "\(Int(model.batchProgress * 100))%")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: model.batchProgress)
                        .progressViewStyle(.linear)
                }
            } else if let summary = model.lastBatchSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if model.isScanning || model.importingID != nil {
                    ProgressView().controlSize(.small)
                    Text(model.isScanning ? model.scanStatus : "Adding to Photos…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if model.outputDirectory != nil {
                    Button(action: model.revealOutputDirectory) {
                        Label("Open export folder", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                } else {
                    Text("Original files stay untouched.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 5)
                if model.isConverting {
                    Button(model.cancellationRequested ? "Stopping…" : "Stop", action: model.cancelConversion)
                        .disabled(model.cancellationRequested)
                        .controlSize(.large)
                } else {
                    if model.retryableFailureCount > 0 {
                        Button("Retry Failed", action: model.retryFailed)
                            .disabled(model.isBusy)
                    }
                    Button(action: model.startConversion) {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(model.pendingCount > 0 ? "Convert \(model.pendingCount) \(model.pendingCount == 1 ? "Photo" : "Photos")" : "Convert Photos")
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.pendingCount == 0)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color.bridgeSurface.opacity(0.4))
    }
}

@MainActor
private struct QueueRow: View {
    let job: ConversionJob
    @ObservedObject var model: AppModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 13) {
                PhotoThumbnail(url: job.sourceURL, maxPixelSize: 144, fill: true)
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.sourceURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(job.sourceURL.path)
                    if let source = job.source {
                        Label(source.format.displayName, systemImage: source.pairedVideoURL == nil ? "photo" : "link")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.bridgeAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.bridgeAccent.opacity(0.07), in: Capsule())
                            .accessibilityLabel("Detected source: \(source.format.displayName)")
                    } else {
                        Label(job.result == nil ? "Unrecognized source" : "Source unavailable", systemImage: "questionmark.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Text(job.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                        .lineLimit(job.state == .failed ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if job.state == .queued || job.state == .cancelled {
                        Text(ByteCountFormatter.string(fromByteCount: job.byteCount, countStyle: .file))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if job.state == .converting {
                        ProgressView(value: job.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 220)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    statusBadge
                    HStack(spacing: 10) {
                        if job.result != nil {
                            rowButton("Preview", icon: "play.rectangle") { model.showPreview(for: job) }
                            rowButton("Show export in Finder", icon: "folder") { model.revealExport(for: job) }
                        }
                        if job.state == .failed || job.state == .cancelled {
                            rowButton(job.source == nil ? "Recheck source" : "Queue for retry", icon: "arrow.clockwise") { model.retry(job.id) }
                                .disabled(model.isBusy)
                        }
                        rowButton("Remove from queue", icon: "xmark") { model.remove(job.id) }
                            .disabled(model.isBusy)
                    }
                }
            }
            if let result = job.result {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                    Text(result.outputFormat.displayName)
                        .fontWeight(.medium)
                    Text(result.outputFormat.fileDescription)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Exported format: \(result.outputFormat.displayName). \(result.outputFormat.fileDescription)")
            }
            if let importError = job.importError {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(importError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
            if job.result?.supportsPhotosImport == true && job.state != .imported {
                Button(job.importError == nil ? "Add this Live Photo to Photos" : "Retry Photos import") {
                    model.importExported(job.id)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(model.isBusy)
            }
            if let result = job.result, job.source != nil, result.outputFormat != model.outputFormat {
                Button("Queue for \(model.outputFormat.displayName)") { model.requeueForDestination(job.id) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .disabled(model.isBusy)
                    .help("Keep the existing export and queue a new conversion to the selected format")
            }
            if !job.notes.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    Text(job.notes.joined(separator: "\n\n"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                } label: {
                    Label("Notes (\(job.notes.count))", systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(13)
        .background(Color.bridgeSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.055)))
    }

    private var statusBadge: some View {
        let status: (String, String, Color)
        switch job.state {
        case .queued: status = ("Ready", "circle", .secondary)
        case .converting: status = ("Converting", "arrow.triangle.2.circlepath", .bridgeAccent)
        case .exported: status = ("Exported", "checkmark.circle.fill", .teal)
        case .imported: status = ("In Photos", "checkmark.circle.fill", .green)
        case .failed: status = ("Needs attention", "exclamationmark.circle.fill", .orange)
        case .cancelled: status = ("Stopped", "pause.circle", .secondary)
        }
        return Label(status.0, systemImage: status.1)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(status.2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.2.opacity(0.08), in: Capsule())
    }

    private func rowButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 20, height: 19)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(LinearGradient(colors: [.bridgeAccent, .bridgeBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: "livephoto")
                    .font(.system(size: size * 0.57, weight: .light))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .bridgeAccent.opacity(0.18), radius: size * 0.18, y: size * 0.08)
            .accessibilityHidden(true)
    }
}
