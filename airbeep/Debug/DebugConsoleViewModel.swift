import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Engine

/// Failures surfaced by the debug console.
struct DebugConsoleError: Error {
    let message: String
}

/// The file plumbing behind the debug console.
///
/// AirBeep ships the AirLift core as a prebuilt xcframework, and that core
/// already exposes the two operations a console needs: `al_exploit_read_file`
/// (one absolute path, raw bytes out) and `al_exploit_write_dir` (every file
/// in a staging directory, written into one target directory). So the console
/// needs no new native code at all — it reuses the transport the tone tooling
/// already uses and only changes the paths.
enum DebugConsoleEngine {

    /// A single payload is capped at 8 MiB: the core stages it on the device,
    /// and a bigger file is a slower session, not a different one.
    static let maxPayloadBytes = 8 * 1024 * 1024

    /// Split an absolute path into the directory and the bare file name the
    /// writer needs: the staged file keeps the name, the directory is where
    /// the core puts it.
    static func split(_ path: String) -> (directory: String, leaf: String)? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let ns = trimmed as NSString
        let leaf = ns.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return nil }
        var directory = ns.deletingLastPathComponent
        if directory.isEmpty { directory = "/" }
        return (directory, leaf)
    }

    /// Read one file off the device, through the AirLift escape.
    static func read(path: String, pairingPath: String) async throws -> Data {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw DebugConsoleError(message: String(localized: "That is not an absolute path"))
        }
        return try await AirliftToneTransport.shared.read(path: trimmed, pairingPath: pairingPath)
    }

    /// Write one file to an arbitrary path, through the AirLift escape.
    static func write(path: String, data: Data, pairingPath: String) async throws {
        guard let (directory, leaf) = split(path) else {
            throw DebugConsoleError(message: String(localized: "That is not an absolute path"))
        }
        guard data.count <= maxPayloadBytes else {
            throw DebugConsoleError(
                message: String(
                    format: String(localized: "The payload is larger than %@ bytes"),
                    maxPayloadBytes.formatted()
                )
            )
        }
        try await AirliftToneTransport.shared.write(
            files: [AirliftToneFile(name: leaf, data: data)],
            to: directory,
            pairingPath: pairingPath
        )
    }

    /// A hex dump of the first bytes of a payload, for binary files.
    static func hexDump(_ data: Data, limit: Int = 512) -> String {
        var out = ""
        for (offset, byte) in data.prefix(limit).enumerated() {
            if offset % 16 == 0 {
                if offset > 0 { out += "\n" }
                out += String(format: "%08x  ", offset)
            }
            out += String(format: "%02x ", byte)
        }
        if data.count > limit {
            out += String(format: "\n… %@ more byte(s)", (data.count - limit).formatted())
        }
        return out
    }
}

// MARK: - Source

/// Where the bytes of a write or an export come from.
enum DebugConsoleSource: String, CaseIterable, Identifiable {
    case editor
    case imported
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return String(localized: "Editor")
        case .imported: return String(localized: "Imported")
        case .device: return String(localized: "Device")
        }
    }
}

// MARK: - Status

/// The outcome of the last operation, painted as a banner.
enum DebugConsoleStatus: Equatable {
    case idle
    case working(String)
    case success(String)
    case warning(String)
    case failure(String)
}

// MARK: - Quick paths

/// Paths worth one tap.
enum DebugConsolePaths {
    static let announcement = "/var/mobile/Library/CallServices/Greetings/default/StartDisclosure.caf"
    static let greetings = "/var/mobile/Library/CallServices/Greetings/default"
    static let media = "/var/mobile/Media"
    static let preferences = "/var/mobile/Library/Preferences"
    static let library = "/var/mobile/Library"
    static let mobile = "/var/mobile"
}

// MARK: - Export document

/// A single file the console can hand to the Files app.
struct DebugConsoleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - View model

/// The state behind the debug console.
///
/// Every device call is blocking in the core, so it runs off the main thread;
/// the actor in `AirliftToneTransport` keeps the calls serialised, because the
/// device tolerates one AirLift session at a time.
@MainActor
final class DebugConsoleViewModel: ObservableObject {

    // MARK: state

    @Published var path: String = DebugConsolePaths.announcement
    @Published var content: String = ""
    @Published var source: DebugConsoleSource = .editor
    @Published var status: DebugConsoleStatus = .idle
    @Published var busy = false
    @Published var log: [String] = []
    /// The bytes of the last file read off the device.
    @Published var deviceData: Data?
    /// The bytes of the file picked in the Files app.
    @Published var importedData: Data?
    @Published var importedName: String?
    /// A binary payload is shown as a hex dump instead of as text.
    @Published var showHex = false
    /// The selected slice of the editor content, as character offsets.
    @Published var selectionStart = 0
    @Published var selectionEnd = 0
    /// The file prepared for the share sheet.
    @Published var exportURL: URL?
    /// The same file, as a document for the Files app.
    @Published var exportDocument: DebugConsoleDocument?
    @Published var exportName = "export.bin"

    // MARK: derived

    /// The selected slice of the editor content.
    var selectedText: String {
        let text = content
        guard !text.isEmpty else { return "" }
        let lower = max(0, min(selectionStart, selectionEnd))
        let upper = min(text.count, max(selectionStart, selectionEnd))
        guard lower < upper else { return "" }
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        return String(text[start..<end])
    }

    /// The bytes a write or an export should use, according to the source picker.
    func payloadData() -> Data? {
        switch source {
        case .editor: return Data(content.utf8)
        case .imported: return importedData
        case .device: return deviceData
        }
    }

    var payloadSize: Int {
        payloadData()?.count ?? 0
    }

    // MARK: read

    /// Read the file at the path, through the escape, and show its content.
    func read() {
        guard begin() else { return }
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            status = .failure(String(localized: "Enter a path first."))
            busy = false
            return
        }

        status = .working(String(format: String(localized: "Reading %@…"), target))
        append("── read \(target) ──")

        let pairingPath = PairingController.pairingFilePath()

        Task {
            do {
                let data = try await DebugConsoleEngine.read(path: target, pairingPath: pairingPath)
                deviceData = data
                if let text = String(data: data, encoding: .utf8) {
                    content = text
                    showHex = false
                    status = .success(
                        String(
                            format: String(localized: "Read %@ bytes from %@"),
                            data.count.formatted(),
                            target
                        )
                    )
                } else {
                    content = DebugConsoleEngine.hexDump(data)
                    showHex = true
                    status = .warning(
                        String(
                            format: String(localized: "Read %@ bytes — the file is not text, so a hex dump is shown"),
                            data.count.formatted()
                        )
                    )
                }
                selectionStart = 0
                selectionEnd = content.count
                append("✓ \(data.count.formatted()) byte(s)")
            } catch {
                report(error)
            }
            busy = false
        }
    }

    // MARK: write

    /// Write to the path, through the escape.
    ///
    /// `onlySelection` writes just the selected slice of the editor content.
    func write(onlySelection: Bool = false) {
        guard begin() else { return }
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            status = .failure(String(localized: "Enter a path first."))
            busy = false
            return
        }

        let payload: Data
        if onlySelection {
            payload = Data(selectedText.utf8)
        } else if let data = payloadData() {
            payload = data
        } else {
            status = .failure(String(localized: "There is nothing to write yet."))
            busy = false
            return
        }

        status = .working(
            String(
                format: String(localized: "Writing %@ bytes to %@…"),
                payload.count.formatted(),
                target
            )
        )
        append("── write \(target) ──")

        let pairingPath = PairingController.pairingFilePath()

        Task {
            do {
                try await DebugConsoleEngine.write(path: target, data: payload, pairingPath: pairingPath)
                status = .success(
                    String(
                        format: String(localized: "Wrote %@ bytes to %@"),
                        payload.count.formatted(),
                        target
                    )
                )
                append("✓ \(payload.count.formatted()) byte(s) written")
            } catch {
                report(error)
            }
            busy = false
        }
    }

    // MARK: import

    /// Take a file from the Files app and keep its bytes.
    func adoptImportedFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            importedData = data
            importedName = url.lastPathComponent
            source = .imported
            status = .success(
                String(
                    format: String(localized: "Imported %@ (%@ bytes)"),
                    url.lastPathComponent,
                    data.count.formatted()
                )
            )
            append("── import \(url.lastPathComponent) ──")
            append("✓ \(data.count.formatted()) byte(s)")
        } catch {
            let message = String(format: String(localized: "Import failed: %@"), error.localizedDescription)
            status = .failure(message)
            append("✗ " + message)
        }
    }

    // MARK: export

    /// Prepare the current payload for the share sheet and the Files app.
    func prepareExport() {
        guard let data = payloadData() else {
            status = .failure(String(localized: "There is nothing to export yet."))
            return
        }
        let leaf = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        let name = leaf.isEmpty ? "export.bin" : leaf
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AirBeep-Debug-\(UUID().uuidString)", directoryHint: .isDirectory)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: name)
            try data.write(to: url, options: .atomic)
            exportURL = url
            exportDocument = DebugConsoleDocument(data: data)
            exportName = name
            status = .success(
                String(
                    format: String(localized: "Exported %@ bytes as %@"),
                    data.count.formatted(),
                    name
                )
            )
            append("── export \(name) ──")
            append("✓ \(data.count.formatted()) byte(s)")
        } catch {
            let message = String(format: String(localized: "Export failed: %@"), error.localizedDescription)
            status = .failure(message)
            append("✗ " + message)
        }
    }

    // MARK: selection

    func selectAll() {
        selectionStart = 0
        selectionEnd = content.count
    }

    /// Keep only the selected slice in the editor.
    func extractSelection() {
        let slice = selectedText
        guard !slice.isEmpty else { return }
        content = slice
        selectionStart = 0
        selectionEnd = slice.count
        status = .success(String(format: String(localized: "Kept %@ character(s)"), slice.count.formatted()))
    }

    /// Copy the selected slice to the clipboard.
    func copySelection() {
        let slice = selectedText
        guard !slice.isEmpty else { return }
        UIPasteboard.general.string = slice
        status = .success(
            String(format: String(localized: "Copied %@ character(s) to the clipboard"), slice.count.formatted())
        )
    }

    /// Put the imported file into the editor, as text when it is text.
    func loadImportedIntoEditor() {
        guard let data = importedData else { return }
        if let text = String(data: data, encoding: .utf8) {
            content = text
            showHex = false
            selectionStart = 0
            selectionEnd = text.count
            status = .success(String(localized: "Loaded the imported file into the editor"))
        } else {
            content = DebugConsoleEngine.hexDump(data)
            showHex = true
            status = .warning(String(localized: "The imported file is not text, so a hex dump is shown"))
        }
    }

    // MARK: plumbing

    /// Common guard for every device operation.
    private func begin() -> Bool {
        guard !busy else { return false }
        guard !CallRecordingToneService.shared.isBusy else {
            status = .failure(String(localized: "The device is busy with another run."))
            return false
        }
        busy = true
        return true
    }

    private func report(_ error: Error) {
        let message: String
        if let consoleError = error as? DebugConsoleError {
            message = consoleError.message
        } else {
            message = error.localizedDescription
        }
        status = .failure(message)
        append("✗ " + message)
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
