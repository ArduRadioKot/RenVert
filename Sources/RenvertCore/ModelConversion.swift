import Foundation
import ModelIO

/// 3D meshes through Model I/O: OBJ, STL, PLY and USD in any direction, USDZ as a source.
public struct ModelConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        let sourceExt = FormatRegistry.preferredExtension(for: detected)
        let targetExt = FormatRegistry.preferredExtension(for: spec.format)
        guard MDLAsset.canImportFileExtension(sourceExt), MDLAsset.canExportFileExtension(targetExt) else {
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: spec.format.rawValue)
        }

        // Model I/O picks its importer from the extension, and after the rename the file
        // carries the target's. A link with the original extension points it at the right one.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("renvert-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("model").appendingPathExtension(sourceExt)
        try FileManager.default.createSymbolicLink(at: input, withDestinationURL: source)

        let asset = MDLAsset(url: input)
        guard asset.count > 0 else {
            throw RenvertError.invalidInput(L("Could not read the 3D model."))
        }
        context.onProgress?(0.5)
        try context.cancellation.throwIfCancelled()
        try asset.export(to: destination)
        context.onProgress?(1)
    }
}
