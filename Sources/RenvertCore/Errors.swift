import Foundation

public enum RenvertError: Error, LocalizedError, Equatable {
    case notAConversion
    case emptyStem
    case unknownFormat(String)
    case invalidModifier(String)
    case unsupportedConversion(from: String, to: String)
    case formatMismatch(expected: String, actual: String)
    case fileNotFound(String)
    case fileBusy(String)
    case notEnoughSpace
    case cancelled
    case invalidInput(String)
    case converterFailed(String)
    case toolMissing(String)
    case permissionDenied(String)
    case pathTraversal
    case journalInconsistent
    case destinationConflict(String)
    case symlinkSkipped
    case stillDownloading
    case unreadableSource

    public var errorDescription: String? {
        switch self {
        case .notAConversion:
            return L("The new name is not a conversion command.")
        case .emptyStem:
            return L("The file name has no stem.")
        case .unknownFormat(let token):
            return L("Unknown format “\(token)”.")
        case .invalidModifier(let token):
            return L("Invalid modifier “\(token)”.")
        case .unsupportedConversion(let from, let to):
            return L("Conversion from \(from) to \(to) is not supported.")
        case .formatMismatch(let expected, let actual):
            return L("Expected \(expected) but produced \(actual).")
        case .fileNotFound(let path):
            return L("File not found: \(path)")
        case .fileBusy(let path):
            return L("File is still changing: \(path)")
        case .notEnoughSpace:
            return L("Not enough free disk space.")
        case .cancelled:
            return L("The conversion was cancelled.")
        case .invalidInput(let reason):
            return reason
        case .converterFailed(let reason):
            return reason
        case .toolMissing(let name):
            return L("Required tool “\(name)” is not available.")
        case .permissionDenied(let path):
            return L("Permission denied: \(path)")
        case .pathTraversal:
            return L("Archive entry points outside the destination.")
        case .journalInconsistent:
            return L("An interrupted operation could not be recovered cleanly.")
        case .destinationConflict(let path):
            return L("Destination already exists: \(path)")
        case .symlinkSkipped:
            return L("Symbolic links are not converted.")
        case .stillDownloading:
            return L("The file is still downloading from iCloud.")
        case .unreadableSource:
            return L("The source file could not be read.")
        }
    }
}
