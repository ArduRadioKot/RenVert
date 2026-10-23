import Foundation

public struct ArchiveConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        if detected == .folder {
            try archiveFolder(source, to: destination, format: spec.format)
            return
        }
        try transcodeArchive(source, to: destination, format: spec.format)
        context.onProgress?(1)
    }

    public func archiveFolder(_ folder: URL, to destination: URL, format: FormatID) throws {
        switch format {
        case .zip, .cbz:
            let result = ProcessRunner.run(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", folder.path, destination.path]
            )
            guard result.exitCode == 0 else { throw RenvertError.converterFailed(result.stderr) }
        case .tar, .cbt:
            let result = ProcessRunner.run(
                executable: "/usr/bin/tar",
                arguments: ["-cf", destination.path, "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent]
            )
            guard result.exitCode == 0 else { throw RenvertError.converterFailed(result.stderr) }
        case .tgz:
            let result = ProcessRunner.run(
                executable: "/usr/bin/tar",
                arguments: ["-czf", destination.path, "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent]
            )
            guard result.exitCode == 0 else { throw RenvertError.converterFailed(result.stderr) }
        default:
            throw RenvertError.unsupportedConversion(from: "folder", to: format.rawValue)
        }
    }

    private func transcodeArchive(_ source: URL, to destination: URL, format: FormatID) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-arch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try extract(source, to: temp)
        try assertNoTraversal(root: temp)
        try archiveFolder(temp, to: destination, format: format)
    }

    private func extract(_ source: URL, to dest: URL) throws {
        let ext = source.pathExtension.lowercased()
        if ["zip", "cbz"].contains(ext) {
            let result = ProcessRunner.run(executable: "/usr/bin/ditto", arguments: ["-x", "-k", source.path, dest.path])
            guard result.exitCode == 0 else { throw RenvertError.converterFailed(result.stderr) }
            return
        }
        if ["tar", "tgz", "cbt"].contains(ext) || source.lastPathComponent.lowercased().hasSuffix(".tar.gz") {
            let result = ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-xf", source.path, "-C", dest.path])
            guard result.exitCode == 0 else { throw RenvertError.converterFailed(result.stderr) }
            return
        }
        throw RenvertError.unsupportedConversion(from: ext, to: "archive")
    }

    private func assertNoTraversal(root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let file = enumerator?.nextObject() as? URL {
            let resolved = file.resolvingSymlinksInPath().path
            if !resolved.hasPrefix(rootPath) {
                throw RenvertError.pathTraversal
            }
        }
    }
}
