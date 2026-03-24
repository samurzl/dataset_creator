import Foundation

struct DatasetRowInput: Equatable {
    var caption: String
    var nsync: DatasetNSync
}

extension DatasetRowInput {
    init(caption: String, categories: [String]) {
        self.init(
            caption: caption,
            nsync: DatasetNSync(
                categories: categories,
                negatives: [
                    DatasetNegative(
                        media: .synthetic,
                        caption: caption,
                        prompt: caption
                    )
                ],
                anchors: categories.map { category in
                    DatasetAnchor(requiredCategories: [category], extraRandomCategory: false)
                }
            )
        )
    }
}

struct DatasetRow: Codable, Equatable {
    var caption: String
    var mediaPath: String
    var nsync: DatasetNSync
    var extras: [String: JSONValue] = [:]

    private enum CodingKeys {
        static let caption = "caption"
        static let mediaPath = "media_path"
        static let nsync = "nsync"
    }

    init(caption: String, mediaPath: String, nsync: DatasetNSync, extras: [String: JSONValue] = [:]) {
        self.caption = caption
        self.mediaPath = mediaPath
        self.nsync = nsync
        self.extras = extras
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        caption = try container.decode(String.self, forKey: AnyCodingKey(CodingKeys.caption))
        mediaPath = try container.decode(String.self, forKey: AnyCodingKey(CodingKeys.mediaPath))
        nsync = try container.decode(DatasetNSync.self, forKey: AnyCodingKey(CodingKeys.nsync))

        var decodedExtras: [String: JSONValue] = [:]
        for key in container.allKeys {
            guard key.stringValue != CodingKeys.caption,
                  key.stringValue != CodingKeys.mediaPath,
                  key.stringValue != CodingKeys.nsync else {
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
        try container.encode(nsync, forKey: AnyCodingKey(CodingKeys.nsync))

        for key in extras.keys.sorted() {
            guard key != CodingKeys.caption, key != CodingKeys.mediaPath, key != CodingKeys.nsync else {
                continue
            }
            try container.encode(extras[key], forKey: AnyCodingKey(key))
        }
    }
}

struct DatasetNSync: Codable, Equatable {
    var categories: [String]
    var negatives: [DatasetNegative]
    var anchors: [DatasetAnchor] = []

    private enum CodingKeys {
        static let categories = "categories"
        static let negatives = "negatives"
        static let anchors = "anchors"
    }

    init(categories: [String], negatives: [DatasetNegative], anchors: [DatasetAnchor] = []) {
        self.categories = categories
        self.negatives = negatives
        self.anchors = anchors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        categories = try container.decode([String].self, forKey: AnyCodingKey(CodingKeys.categories))
        negatives = try container.decode([DatasetNegative].self, forKey: AnyCodingKey(CodingKeys.negatives))
        anchors = try container.decodeIfPresent([DatasetAnchor].self, forKey: AnyCodingKey(CodingKeys.anchors)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(categories, forKey: AnyCodingKey(CodingKeys.categories))
        try container.encode(negatives, forKey: AnyCodingKey(CodingKeys.negatives))
        if !anchors.isEmpty {
            try container.encode(anchors, forKey: AnyCodingKey(CodingKeys.anchors))
        }
    }
}

struct DatasetNegative: Codable, Equatable {
    var media: DatasetNegativeMedia
    var caption: String
    var prompt: String?

    private enum CodingKeys {
        static let media = "media"
        static let caption = "caption"
        static let prompt = "prompt"
    }

    init(media: DatasetNegativeMedia, caption: String, prompt: String? = nil) {
        self.media = media
        self.caption = caption
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        media = try container.decode(DatasetNegativeMedia.self, forKey: AnyCodingKey(CodingKeys.media))
        caption = try container.decode(String.self, forKey: AnyCodingKey(CodingKeys.caption))
        prompt = try container.decodeIfPresent(String.self, forKey: AnyCodingKey(CodingKeys.prompt))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(media, forKey: AnyCodingKey(CodingKeys.media))
        try container.encode(caption, forKey: AnyCodingKey(CodingKeys.caption))
        if let prompt {
            try container.encode(prompt, forKey: AnyCodingKey(CodingKeys.prompt))
        }
    }
}

enum DatasetNegativeMedia: String, Codable, CaseIterable, Equatable {
    case positive
    case synthetic
}

struct DatasetAnchor: Codable, Equatable {
    var requiredCategories: [String]
    var extraRandomCategory: Bool

    private enum CodingKeys {
        static let requiredCategories = "required_categories"
        static let extraRandomCategory = "extra_random_category"
    }

    init(requiredCategories: [String], extraRandomCategory: Bool) {
        self.requiredCategories = requiredCategories
        self.extraRandomCategory = extraRandomCategory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        requiredCategories = try container.decode([String].self, forKey: AnyCodingKey(CodingKeys.requiredCategories))
        extraRandomCategory = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey(CodingKeys.extraRandomCategory)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(requiredCategories, forKey: AnyCodingKey(CodingKeys.requiredCategories))
        if extraRandomCategory {
            try container.encode(true, forKey: AnyCodingKey(CodingKeys.extraRandomCategory))
        }
    }
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
    case missingNSync(row: Int)
    case invalidNSync(row: Int)
    case invalidStringArray(row: Int, keyPath: String)
    case emptyList(row: Int, keyPath: String)
    case invalidNegative(row: Int, index: Int)
    case invalidNegativeMedia(row: Int, index: Int, value: String)
    case missingNegativePrompt(row: Int, index: Int)
    case forbiddenNegativePrompt(row: Int, index: Int)
    case blankNegativeCaption(row: Int, index: Int)
    case blankNegativePrompt(row: Int, index: Int)
    case invalidAnchors(row: Int)
    case invalidAnchor(row: Int, index: Int)
    case legacyNegativeColumn(row: Int, key: String)
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
        case let .missingNSync(row):
            return "Row \(row + 1) is missing 'nsync'. Advanced NSYNC requires it on every row."
        case let .invalidNSync(row):
            return "Row \(row + 1) has an invalid 'nsync' object."
        case let .invalidStringArray(row, keyPath):
            return "Row \(row + 1) has an invalid string list at '\(keyPath)'."
        case let .emptyList(row, keyPath):
            return "Row \(row + 1) has an empty '\(keyPath)' list."
        case let .invalidNegative(row, index):
            return "Row \(row + 1) has an invalid negative entry at index \(index)."
        case let .invalidNegativeMedia(row, index, value):
            return "Row \(row + 1) negative \(index + 1) has unsupported media '\(value)'."
        case let .missingNegativePrompt(row, index):
            return "Row \(row + 1) negative \(index + 1) requires 'prompt' when media is synthetic."
        case let .forbiddenNegativePrompt(row, index):
            return "Row \(row + 1) negative \(index + 1) must not include 'prompt' when media is positive."
        case let .blankNegativeCaption(row, index):
            return "Row \(row + 1) negative \(index + 1) must include a non-empty caption."
        case let .blankNegativePrompt(row, index):
            return "Row \(row + 1) negative \(index + 1) must include a non-empty prompt."
        case let .invalidAnchors(row):
            return "Row \(row + 1) has an invalid 'anchors' list."
        case let .invalidAnchor(row, index):
            return "Row \(row + 1) anchor \(index + 1) is invalid."
        case let .legacyNegativeColumn(row, key):
            return "Row \(row + 1) uses legacy column '\(key)'. Advanced NSYNC cannot be mixed with legacy negative columns."
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
                nsync: input.nsync,
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
        if object.keys.contains("negative_caption") {
            throw DatasetStoreError.legacyNegativeColumn(row: rowIndex, key: "negative_caption")
        }
        if object.keys.contains("negative_media_path") {
            throw DatasetStoreError.legacyNegativeColumn(row: rowIndex, key: "negative_media_path")
        }

        guard let caption = object["caption"] as? String else {
            throw DatasetStoreError.missingString(row: rowIndex, key: "caption")
        }
        guard let mediaPath = object["media_path"] as? String else {
            throw DatasetStoreError.missingString(row: rowIndex, key: "media_path")
        }
        guard let rawNSync = object["nsync"] as? [String: Any] else {
            if object.keys.contains("nsync") {
                throw DatasetStoreError.invalidNSync(row: rowIndex)
            }
            throw DatasetStoreError.missingNSync(row: rowIndex)
        }

        let nsync = try rawNSyncValue(rowIndex: rowIndex, object: rawNSync)

        var extras: [String: JSONValue] = [:]
        for (key, value) in object {
            guard key != "caption", key != "media_path", key != "nsync" else {
                continue
            }
            extras[key] = try jsonValue(from: value)
        }

        return DatasetRow(
            caption: caption,
            mediaPath: mediaPath,
            nsync: nsync,
            extras: extras
        )
    }

    private func rawNSyncValue(rowIndex: Int, object: [String: Any]) throws -> DatasetNSync {
        let categories = try nonEmptyStringList(
            rawValue: object["categories"],
            rowIndex: rowIndex,
            keyPath: "nsync.categories"
        )

        guard let rawNegatives = object["negatives"] as? [Any] else {
            if object["negatives"] == nil {
                throw DatasetStoreError.emptyList(row: rowIndex, keyPath: "nsync.negatives")
            }
            throw DatasetStoreError.invalidStringArray(row: rowIndex, keyPath: "nsync.negatives")
        }

        guard !rawNegatives.isEmpty else {
            throw DatasetStoreError.emptyList(row: rowIndex, keyPath: "nsync.negatives")
        }

        let negatives = try rawNegatives.enumerated().map { negativeIndex, rawValue in
            guard let object = rawValue as? [String: Any] else {
                throw DatasetStoreError.invalidNegative(row: rowIndex, index: negativeIndex)
            }
            return try rawNegativeValue(rowIndex: rowIndex, negativeIndex: negativeIndex, object: object)
        }

        let anchors: [DatasetAnchor]
        if let rawAnchors = object["anchors"] {
            guard let anchorArray = rawAnchors as? [Any] else {
                throw DatasetStoreError.invalidAnchors(row: rowIndex)
            }
            anchors = try anchorArray.enumerated().map { anchorIndex, rawValue in
                guard let object = rawValue as? [String: Any] else {
                    throw DatasetStoreError.invalidAnchor(row: rowIndex, index: anchorIndex)
                }
                return try rawAnchorValue(rowIndex: rowIndex, anchorIndex: anchorIndex, object: object)
            }
        } else {
            anchors = []
        }

        return DatasetNSync(categories: categories, negatives: negatives, anchors: anchors)
    }

    private func rawNegativeValue(rowIndex: Int, negativeIndex: Int, object: [String: Any]) throws -> DatasetNegative {
        guard let mediaValue = object["media"] as? String else {
            throw DatasetStoreError.invalidNegative(row: rowIndex, index: negativeIndex)
        }
        guard let media = DatasetNegativeMedia(rawValue: mediaValue) else {
            throw DatasetStoreError.invalidNegativeMedia(row: rowIndex, index: negativeIndex, value: mediaValue)
        }

        guard let caption = object["caption"] as? String else {
            throw DatasetStoreError.blankNegativeCaption(row: rowIndex, index: negativeIndex)
        }
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatasetStoreError.blankNegativeCaption(row: rowIndex, index: negativeIndex)
        }

        switch media {
        case .positive:
            if object.keys.contains("prompt") {
                throw DatasetStoreError.forbiddenNegativePrompt(row: rowIndex, index: negativeIndex)
            }
            return DatasetNegative(media: .positive, caption: caption, prompt: nil)
        case .synthetic:
            guard let prompt = object["prompt"] as? String else {
                throw DatasetStoreError.missingNegativePrompt(row: rowIndex, index: negativeIndex)
            }
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DatasetStoreError.blankNegativePrompt(row: rowIndex, index: negativeIndex)
            }
            return DatasetNegative(media: .synthetic, caption: caption, prompt: prompt)
        }
    }

    private func rawAnchorValue(rowIndex: Int, anchorIndex: Int, object: [String: Any]) throws -> DatasetAnchor {
        let requiredCategories = try nonEmptyStringList(
            rawValue: object["required_categories"],
            rowIndex: rowIndex,
            keyPath: "nsync.anchors[\(anchorIndex)].required_categories"
        )

        let extraRandomCategory = pythonBool(from: object["extra_random_category"])
        return DatasetAnchor(
            requiredCategories: requiredCategories,
            extraRandomCategory: extraRandomCategory
        )
    }

    private func nonEmptyStringList(rawValue: Any?, rowIndex: Int, keyPath: String) throws -> [String] {
        guard let array = rawValue as? [Any] else {
            throw DatasetStoreError.invalidStringArray(row: rowIndex, keyPath: keyPath)
        }
        guard !array.isEmpty else {
            throw DatasetStoreError.emptyList(row: rowIndex, keyPath: keyPath)
        }

        var normalized: [String] = []
        var seen: Set<String> = []
        for value in array {
            guard let string = value as? String else {
                throw DatasetStoreError.invalidStringArray(row: rowIndex, keyPath: keyPath)
            }
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DatasetStoreError.invalidStringArray(row: rowIndex, keyPath: keyPath)
            }
            if seen.insert(string).inserted {
                normalized.append(string)
            }
        }
        return normalized
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

        if row.extras.keys.contains("negative_caption") {
            throw DatasetStoreError.legacyNegativeColumn(row: rowIndex, key: "negative_caption")
        }
        if row.extras.keys.contains("negative_media_path") {
            throw DatasetStoreError.legacyNegativeColumn(row: rowIndex, key: "negative_media_path")
        }

        let categories = try normalizedUniqueNonEmptyStrings(
            row.nsync.categories,
            rowIndex: rowIndex,
            keyPath: "nsync.categories"
        )
        guard !categories.isEmpty else {
            throw DatasetStoreError.emptyList(row: rowIndex, keyPath: "nsync.categories")
        }

        guard !row.nsync.negatives.isEmpty else {
            throw DatasetStoreError.emptyList(row: rowIndex, keyPath: "nsync.negatives")
        }

        let negatives = try row.nsync.negatives.enumerated().map { negativeIndex, negative in
            let trimmedNegativeCaption = negative.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedNegativeCaption.isEmpty else {
                throw DatasetStoreError.blankNegativeCaption(row: rowIndex, index: negativeIndex)
            }

            switch negative.media {
            case .positive:
                if negative.prompt != nil {
                    throw DatasetStoreError.forbiddenNegativePrompt(row: rowIndex, index: negativeIndex)
                }
                return DatasetNegative(media: .positive, caption: trimmedNegativeCaption, prompt: nil)
            case .synthetic:
                guard let prompt = negative.prompt else {
                    throw DatasetStoreError.missingNegativePrompt(row: rowIndex, index: negativeIndex)
                }
                let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPrompt.isEmpty else {
                    throw DatasetStoreError.blankNegativePrompt(row: rowIndex, index: negativeIndex)
                }
                return DatasetNegative(media: .synthetic, caption: trimmedNegativeCaption, prompt: trimmedPrompt)
            }
        }

        let anchors = try row.nsync.anchors.enumerated().map { anchorIndex, anchor in
            let requiredCategories = try normalizedUniqueNonEmptyStrings(
                anchor.requiredCategories,
                rowIndex: rowIndex,
                keyPath: "nsync.anchors[\(anchorIndex)].required_categories"
            )

            guard !requiredCategories.isEmpty else {
                throw DatasetStoreError.emptyList(
                    row: rowIndex,
                    keyPath: "nsync.anchors[\(anchorIndex)].required_categories"
                )
            }

            return DatasetAnchor(
                requiredCategories: requiredCategories,
                extraRandomCategory: anchor.extraRandomCategory
            )
        }

        return DatasetRow(
            caption: trimmedCaption,
            mediaPath: trimmedMediaPath,
            nsync: DatasetNSync(categories: categories, negatives: negatives, anchors: anchors),
            extras: row.extras
        )
    }

    private func normalizedUniqueNonEmptyStrings(
        _ values: [String],
        rowIndex: Int,
        keyPath: String
    ) throws -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []

        for value in values {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DatasetStoreError.invalidStringArray(row: rowIndex, keyPath: keyPath)
            }
            if seen.insert(value).inserted {
                normalized.append(value)
            }
        }

        return normalized
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

    private func pythonBool(from rawValue: Any?) -> Bool {
        guard let rawValue else {
            return false
        }

        switch rawValue {
        case let value as Bool:
            return value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }
            return value.doubleValue != 0
        case let value as String:
            return !value.isEmpty
        case let value as [Any]:
            return !value.isEmpty
        case let value as [String: Any]:
            return !value.isEmpty
        case _ as NSNull:
            return false
        default:
            return true
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
