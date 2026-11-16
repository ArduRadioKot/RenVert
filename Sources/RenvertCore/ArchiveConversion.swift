import Foundation

public struct ArchiveConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        if detected == .folder {
            try archiveFolder(source, to: destination, format: spec.format)
            return
        }
        if TensorPack.handles(detected: detected, format: spec.format) {
            try TensorPack.convert(from: source, detected: detected, to: destination, format: spec.format)
            context.onProgress?(1)
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

/// ZIP members NumPy and PyTorch can open. A renamed zip is neither an `.npz` nor a `.pt`.
private enum TensorPack {
    static func handles(detected: FormatID, format: FormatID) -> Bool {
        (detected == .zip && (format == .npz || format == .pt))
            || ((detected == .npz || detected == .pt) && format == .zip)
    }

    static func convert(from source: URL, detected: FormatID, to destination: URL, format: FormatID) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // Both containers are already zip files. Copying keeps the payload intact.
        if format == .zip {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        let files = try unpackedFiles(from: source)
        guard !files.isEmpty else { throw RenvertError.invalidInput(L("The archive has no files.")) }
        guard files.count <= Int(UInt16.max) else { throw RenvertError.invalidInput(L("The archive has too many files.")) }
        let members: [Member]
        if format == .npz {
            members = files.map { Member(name: npyName($0.name), bytes: npyBytes($0.bytes)) }
        } else {
            let stem = destination.deletingPathExtension().lastPathComponent
            let prefix = stem.isEmpty || stem == "." || stem == ".." ? "archive" : stem
            members = [
                Member(name: "\(prefix)/data.pkl", bytes: pickleDict(files)),
                Member(name: "\(prefix)/byteorder", bytes: Data("little".utf8))
            ]
        }
        try storedZip(members).write(to: destination)
    }

    private struct Member {
        var name: String
        var bytes: Data
    }

    private static func unpackedFiles(from source: URL) throws -> [(name: String, bytes: Data)] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-tensor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let result = ProcessRunner.run(executable: "/usr/bin/ditto", arguments: ["-x", "-k", source.path, temp.path])
        guard result.exitCode == 0 else { throw RenvertError.converterFailed(result.stderr) }

        let root = temp.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard let enumerator = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return []
        }
        var found: [(String, Data)] = []
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            let resolved = file.resolvingSymlinksInPath().path
            guard resolved == root || resolved.hasPrefix(prefix) else { throw RenvertError.pathTraversal }
            let relative = String(resolved.dropFirst(prefix.count))
            let parts = relative.split(separator: "/")
            if parts.contains("__MACOSX") { continue }
            if parts.contains(where: { $0 == ".DS_Store" || $0.hasPrefix("._") }) { continue }
            guard !relative.isEmpty, !relative.contains(".."), !relative.hasPrefix("/") else { continue }
            let data = try Data(contentsOf: file)
            guard data.count <= Int(UInt32.max) else {
                throw RenvertError.invalidInput(L("A file in the archive is larger than 4 GB."))
            }
            found.append((relative, data))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    private static let npyMagic = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59])

    private static func npyName(_ relative: String) -> String {
        relative.lowercased().hasSuffix(".npy") ? relative : relative + ".npy"
    }

    /// A file that is already an `.npy` is stored unchanged. Anything else becomes a 1-D uint8 array.
    private static func npyBytes(_ payload: Data) -> Data {
        if payload.count >= 6, payload.prefix(6) == npyMagic { return payload }
        let digits = String(payload.count).count
        let growth = max(0, 21 - digits)
        let text = "{'descr': '|u1', 'fortran_order': False, 'shape': (\(payload.count),), }"
            + String(repeating: " ", count: growth)
        let hlen = text.utf8.count + 1
        let pad = 64 - ((10 + hlen) % 64)
        var header = Data(text.utf8)
        header.append(Data(repeating: 0x20, count: pad))
        header.append(0x0A)
        var out = npyMagic
        out.append(0x01)
        out.append(0x00)
        appendLE16(UInt16(header.count), to: &out)
        out.append(header)
        out.append(payload)
        return out
    }

    /// Protocol 3 dict of path to bytes. PyTorch unpickles this when `weights_only` is off.
    private static func pickleDict(_ files: [(name: String, bytes: Data)]) -> Data {
        var out = Data([0x80, 0x03, 0x7D, 0x28])
        for file in files {
            let name = Data(file.name.utf8)
            out.append(0x58)
            appendLE32(UInt32(name.count), to: &out)
            out.append(name)
            if file.bytes.count < 256 {
                out.append(0x43)
                out.append(UInt8(file.bytes.count))
            } else {
                out.append(0x42)
                appendLE32(UInt32(file.bytes.count), to: &out)
            }
            out.append(file.bytes)
        }
        out.append(0x75)
        out.append(0x2E)
        return out
    }

    private static func storedZip(_ members: [Member]) throws -> Data {
        var local = Data()
        var central = Data()
        for member in members {
            let name = Data(member.name.utf8)
            guard name.count <= Int(UInt16.max), member.bytes.count <= Int(UInt32.max) else {
                throw RenvertError.invalidInput(L("A file in the archive is larger than 4 GB."))
            }
            guard local.count <= Int(UInt32.max) else {
                throw RenvertError.invalidInput(L("A file in the archive is larger than 4 GB."))
            }
            let crc = checksum(member.bytes)
            let offset = UInt32(local.count)
            appendLE32(0x04034B50, to: &local)
            appendLE16(20, to: &local)
            appendLE16(0x0800, to: &local)
            appendLE16(0, to: &local)
            appendLE16(0, to: &local)
            appendLE16(0, to: &local)
            appendLE32(crc, to: &local)
            appendLE32(UInt32(member.bytes.count), to: &local)
            appendLE32(UInt32(member.bytes.count), to: &local)
            appendLE16(UInt16(name.count), to: &local)
            appendLE16(0, to: &local)
            local.append(name)
            local.append(member.bytes)

            appendLE32(0x02014B50, to: &central)
            appendLE16(20, to: &central)
            appendLE16(20, to: &central)
            appendLE16(0x0800, to: &central)
            appendLE16(0, to: &central)
            appendLE16(0, to: &central)
            appendLE16(0, to: &central)
            appendLE32(crc, to: &central)
            appendLE32(UInt32(member.bytes.count), to: &central)
            appendLE32(UInt32(member.bytes.count), to: &central)
            appendLE16(UInt16(name.count), to: &central)
            appendLE16(0, to: &central)
            appendLE16(0, to: &central)
            appendLE16(0, to: &central)
            appendLE16(0, to: &central)
            appendLE32(0x81A40000, to: &central)
            appendLE32(offset, to: &central)
            central.append(name)
        }
        guard local.count <= Int(UInt32.max), central.count <= Int(UInt32.max) else {
            throw RenvertError.invalidInput(L("A file in the archive is larger than 4 GB."))
        }
        var end = Data()
        appendLE32(0x06054B50, to: &end)
        appendLE16(0, to: &end)
        appendLE16(0, to: &end)
        appendLE16(UInt16(members.count), to: &end)
        appendLE16(UInt16(members.count), to: &end)
        appendLE32(UInt32(central.count), to: &end)
        appendLE32(UInt32(local.count), to: &end)
        appendLE16(0, to: &end)
        local.append(central)
        local.append(end)
        return local
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8(value >> 24))
    }
}
