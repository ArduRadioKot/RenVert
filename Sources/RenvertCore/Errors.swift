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
            return String(localized: "The new name is not a conversion command.")
        case .emptyStem:
            return String(localized: "The file name has no stem.")
        case .unknownFormat(let token):
            return String(localized: "Unknown format “\(token)”.")
        case .invalidModifier(let token):
            return String(localized: "Invalid modifier “\(token)”.")
        case .unsupportedConversion(let from, let to):
            return String(localized: "Conversion from \(from) to \(to) is not supported.")
        case .formatMismatch(let expected, let actual):
            return String(localized: "Expected \(expected) but produced \(actual).")
        case .fileNotFound(let path):
            return String(localized: "File not found: \(path)")
        case .fileBusy(let path):
            return String(localized: "File is still changing: \(path)")
        case .notEnoughSpace:
            return String(localized: "Not enough free disk space.")
        case .cancelled:
            return String(localized: "The conversion was cancelled.")
        case .invalidInput(let reason):
            return reason
        case .converterFailed(let reason):
            return reason
        case .toolMissing(let name):
            return String(localized: "Required tool “\(name)” is not available.")
        case .permissionDenied(let path):
            return String(localized: "Permission denied: \(path)")
        case .pathTraversal:
            return String(localized: "Archive entry points outside the destination.")
        case .journalInconsistent:
            return String(localized: "An interrupted operation could not be recovered cleanly.")
        case .destinationConflict(let path):
            return String(localized: "Destination already exists: \(path)")
        case .symlinkSkipped:
            return String(localized: "Symbolic links are not converted.")
        case .stillDownloading:
            return String(localized: "The file is still downloading from iCloud.")
        case .unreadableSource:
            return String(localized: "The source file could not be read.")
        }
    }
}
