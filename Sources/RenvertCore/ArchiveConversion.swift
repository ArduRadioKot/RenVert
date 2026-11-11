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
        case .tgz, .tbz2, .txz, .sevenZ:
            // bsdtar picks the container from --format and the compressor from the flag.
            let mode: [String]
            switch format {
            case .tgz: mode = ["-czf"]
            case .tbz2: mode = ["-cjf"]
            case .txz: mode = ["-cJf"]
            default: mode = ["--format", "7zip", "-cf"]
            }
            let result = ProcessRunner.run(
                executable: "/usr/bin/tar",
                arguments: mode + [destination.path, "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent]
            )
            guard result.exitCode == 0 else { throw RenvertError.converterFailed(result.stderr) }
        default:
            throw RenvertError.unsupportedConversion(from: "folder", to: format.rawValue)
        }
    }

    private func transcodeArchive(_ source: URL, to destination: URL, format: FormatID) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-arch-\(UUID().uuidString)", isDirectory: true)
        // The archive is rebuilt from a folder named after the file, so that name is its top-level entry.
        let stem = source.deletingPathExtension().lastPathComponent
        let root = temp.appendingPathComponent(stem.isEmpty ? "Archive" : stem, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try extract(source, to: root)
        try assertNoTraversal(root: root)
        try archiveFolder(contentRoot(of: root), to: destination, format: format)
    }

    /// An archive that already holds one top-level folder keeps it instead of gaining a second one.
    private func contentRoot(of root: URL) -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return items[0]
        }
        return root
    }

    /// ZIP goes through ditto, which keeps macOS metadata. bsdtar reads everything else by
    /// content: tar with any compressor, 7z and RAR.
    private func extract(_ source: URL, to dest: URL) throws {
        let isZip = (try? FileHandle(forReadingFrom: source)).flatMap { handle -> Bool? in
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 2)) == Data([0x50, 0x4B])
        } ?? false
        let result = isZip
            ? ProcessRunner.run(executable: "/usr/bin/ditto", arguments: ["-x", "-k", source.path, dest.path])
            : ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-xf", source.path, "-C", dest.path])
        guard result.exitCode == 0 else { throw RenvertError.converterFailed(result.stderr) }
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
