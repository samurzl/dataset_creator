import Foundation

struct DatasetRowInput: Equatable {
    var caption: String
}

struct DatasetRow: Codable, Equatable {
    var caption: String
    var mediaPath: String
    var extras: [String: JSONValue] = [:]

    private enum CodingKeys {
        static let caption = "caption"
        static let mediaPath = "media_path"
        static let nsync = "nsync"
        static let negativeCaption = "negative_caption"
        static let negativeMediaPath = "negative_media_path"
    }

    init(caption: String, mediaPath: String, extras: [String: JSONValue] = [:]) {
        self.caption = caption
        self.mediaPath = mediaPath
        self.extras = extras
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        caption = try container.decode(String.self, forKey: AnyCodingKey(CodingKeys.caption))
        mediaPath = try container.decode(String.self, forKey: AnyCodingKey(CodingKeys.mediaPath))

        var decodedExtras: [String: JSONValue] = [:]
        for key in container.allKeys {
            guard !Self.legacyKeys.contains(key.stringValue) else {
                continue
            }
            decodedExtras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        extras = decodedExtras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(caption, forKey: AnyCodingKey(CodingKeys.caption))
        try container.encode(mediaPath, forKey: AnyCodingKey(CodingKeys.mediaPath))

        for key in extras.keys.sorted() {
            guard !Self.legacyKeys.contains(key) else {
                continue
            }
            try container.encode(extras[key], forKey: AnyCodingKey(key))
        }
    }

    private static let legacyKeys: Set<String> = [
        CodingKeys.caption,
        CodingKeys.mediaPath,
        CodingKeys.nsync,
        CodingKeys.negativeCaption,
        CodingKeys.negativeMediaPath
    ]
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(NSNumber)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .number(NSNumber(value: value))
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(NSNumber(value: value))
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            if CFNumberIsFloatType(value) {
                try container.encode(value.doubleValue)
            } else {
                try container.encode(value.int64Value)
            }
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct PreparedDatasetAppend {
    let rows: [DatasetRow]
    let outputMediaURL: URL
}

enum DatasetStoreError: LocalizedError, Equatable {
    case unsupportedDatasetFileFound(name: String)
    case datasetFileNotArray
    case rowNotObject(index: Int)
    case missingString(row: Int, key: String)
    case blankString(row: Int, key: String)
    case duplicateSamplePath(path: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedDatasetFileFound(name):
            return "Unsupported dataset file found: \(name). This app only supports dataset.json."
        case .datasetFileNotArray:
            return "dataset.json must contain a top-level array of objects."
        case let .rowNotObject(index):
            return "Row \(index + 1) in dataset.json must be an object."
        case let .missingString(row, key):
            return "Row \(row + 1) is missing the required string field '\(key)'."
        case let .blankString(row, key):
            return "Row \(row + 1) has a blank '\(key)' field."
        case let .duplicateSamplePath(path):
            return "Multiple rows collapse to the same future sample path '\(path)'."
        }
    }
}

struct DatasetStore {
    let datasetRootURL: URL
    let fileManager: FileManager

    private let supportedPositiveMediaExtensions: Set<String> = [
        "mp4",
        "mov",
        "m4v",
        "mkv",
        "avi",
        "mpg",
        "mpeg",
        "webm",
        "png",
        "jpg",
        "jpeg",
        "webp",
        "heic",
        "heif",
        "bmp",
        "tif",
        "tiff",
        "gif"
    ]

    private let legacyDatasetKeys: Set<String> = [
        "nsync",
        "negative_caption",
        "negative_media_path"
    ]

    init(datasetRootURL: URL, fileManager: FileManager = .default) {
        self.datasetRootURL = datasetRootURL
        self.fileManager = fileManager
    }

    var datasetFileURL: URL {
        datasetRootURL.appendingPathComponent("dataset.json")
    }

    var positiveDirectoryURL: URL {
        datasetRootURL.appendingPathComponent("positive", isDirectory: true)
    }

    func prepareAppend(
        input: DatasetRowInput,
        mediaFileExtension: String = "mp4"
    ) throws -> PreparedDatasetAppend {
        try validateSupportedDatasetFiles()

        let existingRows = try loadRows()
        let nextMediaPath = try nextPositiveMediaPath(
            existingRows: existingRows,
            mediaFileExtension: mediaFileExtension
        )
        let row = try normalizedRow(
            rowIndex: existingRows.count,
            row: DatasetRow(
                caption: input.caption,
                mediaPath: nextMediaPath,
                extras: [:]
            )
        )

        let finalRows = try validatedRows(existingRows + [row])
        let outputMediaURL = datasetRootURL.appendingPathComponent(nextMediaPath)
        return PreparedDatasetAppend(rows: finalRows, outputMediaURL: outputMediaURL)
    }

    func commit(_ preparedAppend: PreparedDatasetAppend) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(preparedAppend.rows)
        try data.write(to: datasetFileURL, options: .atomic)
    }

    func loadRows() throws -> [DatasetRow] {
        guard fileManager.fileExists(atPath: datasetFileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: datasetFileURL)
        let json = try JSONSerialization.jsonObject(with: data)

        guard let array = json as? [Any] else {
            throw DatasetStoreError.datasetFileNotArray
        }

        let rows = try array.enumerated().map { index, rawValue in
            guard let object = rawValue as? [String: Any] else {
                throw DatasetStoreError.rowNotObject(index: index)
            }

            return try rawRow(rowIndex: index, object: object)
        }

        return try validatedRows(rows)
    }

    private func validateSupportedDatasetFiles() throws {
        let unsupportedFileNames = ["dataset.jsonl", "dataset.csv"]
        for fileName in unsupportedFileNames {
            let url = datasetRootURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: url.path) {
                throw DatasetStoreError.unsupportedDatasetFileFound(name: fileName)
            }
        }
    }

    private func rawRow(rowIndex: Int, object: [String: Any]) throws -> DatasetRow {
        guard let caption = object["caption"] as? String else {
            throw DatasetStoreError.missingString(row: rowIndex, key: "caption")
        }
        guard let mediaPath = object["media_path"] as? String else {
            throw DatasetStoreError.missingString(row: rowIndex, key: "media_path")
        }

        var extras: [String: JSONValue] = [:]
        for (key, value) in object {
            guard key != "caption", key != "media_path", !legacyDatasetKeys.contains(key) else {
                continue
            }
            extras[key] = try jsonValue(from: value)
        }

        return DatasetRow(
            caption: caption,
            mediaPath: mediaPath,
            extras: extras
        )
    }

    private func validatedRows(_ rows: [DatasetRow]) throws -> [DatasetRow] {
        let normalizedRows = try rows.enumerated().map(normalizedRow)

        var samplePaths: Set<String> = []
        for row in normalizedRows {
            let collapsedPath = collapsedSamplePath(for: row.mediaPath)
            if !samplePaths.insert(collapsedPath).inserted {
                throw DatasetStoreError.duplicateSamplePath(path: collapsedPath)
            }
        }

        return normalizedRows
    }

    private func normalizedRow(rowIndex: Int, row: DatasetRow) throws -> DatasetRow {
        let trimmedCaption = row.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCaption.isEmpty else {
            throw DatasetStoreError.blankString(row: rowIndex, key: "caption")
        }

        let trimmedMediaPath = row.mediaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMediaPath.isEmpty else {
            throw DatasetStoreError.blankString(row: rowIndex, key: "media_path")
        }

        return DatasetRow(
            caption: trimmedCaption,
            mediaPath: trimmedMediaPath,
            extras: cleanedExtras(row.extras)
        )
    }

    private func cleanedExtras(_ extras: [String: JSONValue]) -> [String: JSONValue] {
        extras.filter { key, _ in
            key != "caption" &&
            key != "media_path" &&
            !legacyDatasetKeys.contains(key)
        }
    }

    private func nextPositiveMediaPath(
        existingRows: [DatasetRow],
        mediaFileExtension: String
    ) throws -> String {
        var maxIndex = 0
        let normalizedExtension = mediaFileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let resolvedExtension = normalizedExtension.isEmpty ? "mp4" : normalizedExtension

        if fileManager.fileExists(atPath: positiveDirectoryURL.path) {
            let urls = try fileManager.contentsOfDirectory(
                at: positiveDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for url in urls where supportedPositiveMediaExtensions.contains(url.pathExtension.lowercased()) {
                if let index = Int(url.deletingPathExtension().lastPathComponent) {
                    maxIndex = max(maxIndex, index)
                }
            }
        }

        for row in existingRows {
            let normalizedPath = normalizePath(row.mediaPath)
            let components = normalizedPath.split(separator: "/")
            guard components.count == 2, components.first == "positive" else {
                continue
            }
            let fileName = String(components[1])
            let baseName = (fileName as NSString).deletingPathExtension
            if let index = Int(baseName) {
                maxIndex = max(maxIndex, index)
            }
        }

        return "positive/\(maxIndex + 1).\(resolvedExtension)"
    }

    private func collapsedSamplePath(for mediaPath: String) -> String {
        let normalizedPath = normalizePath(mediaPath)
        let basePath = (normalizedPath as NSString).deletingPathExtension
        return "\(basePath).pt"
    }

    private func normalizePath(_ path: String) -> String {
        let normalizedSlashes = path.replacingOccurrences(of: "\\", with: "/")
        let isAbsolute = normalizedSlashes.hasPrefix("/")

        var components: [Substring] = []
        for component in normalizedSlashes.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
                continue
            }
            components.append(component)
        }

        let joinedPath = components.map(String.init).joined(separator: "/")
        if isAbsolute {
            return "/\(joinedPath)"
        }
        return joinedPath
    }

    private func jsonValue(from rawValue: Any) throws -> JSONValue {
        switch rawValue {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value)
        case _ as NSNull:
            return .null
        case let value as [Any]:
            return .array(try value.map(jsonValue))
        case let value as [String: Any]:
            return .object(try value.mapValues(jsonValue))
        default:
            let description = String(describing: type(of: rawValue))
            throw NSError(
                domain: "DatasetStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value type: \(description)"]
            )
        }
    }
}

struct DatasetAuthoringService {
    typealias ClipExportOperation = (ClipExportRequest, URL) async throws -> URL

    let fileManager: FileManager
    private let clipExportOperation: ClipExportOperation

    init(
        fileManager: FileManager = .default,
        clipExportOperation: @escaping ClipExportOperation = { request, outputURL in
            try await ClipExporter.exportClip(request: request, to: outputURL)
        }
    ) {
        self.fileManager = fileManager
        self.clipExportOperation = clipExportOperation
    }

    func exportClip(
        request: ClipExportRequest,
        input: DatasetRowInput,
        datasetRootURL: URL
    ) async throws -> URL {
        let store = DatasetStore(datasetRootURL: datasetRootURL, fileManager: fileManager)
        let preparedAppend = try store.prepareAppend(
            input: input,
            mediaFileExtension: request.mediaFileExtension
        )

        try fileManager.createDirectory(
            at: store.positiveDirectoryURL,
            withIntermediateDirectories: true
        )

        do {
            let outputURL = try await clipExportOperation(request, preparedAppend.outputMediaURL)
            do {
                try store.commit(preparedAppend)
                return outputURL
            } catch {
                try? fileManager.removeItem(at: preparedAppend.outputMediaURL)
                throw error
            }
        } catch {
            throw error
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
