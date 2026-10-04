import Foundation

nonisolated enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

nonisolated extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), value.magnitude < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

nonisolated struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

nonisolated struct UsageListResponse: Decodable {
    var data: [UsageRecord]
}

nonisolated struct UsageRecord: Codable, Identifiable, Equatable {
    nonisolated struct Breakdown: Codable, Equatable {
        nonisolated struct Input: Codable, Equatable {
            var totalTokens: Int
            var cacheReadTokens: Int

            enum CodingKeys: String, CodingKey {
                case totalTokens = "total_tokens"
                case cacheReadTokens = "cache_read_tokens"
            }
        }
        nonisolated struct Output: Codable, Equatable {
            var totalTokens: Int

            enum CodingKeys: String, CodingKey {
                case totalTokens = "total_tokens"
            }
        }
        var input: Input
        var output: Output
    }

    var id: String
    var timestamp: String
    var account: String
    var model: String
    var upstreamModel: String
    var stream: Bool
    var status: Int
    var error: String?
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var totalTokens: Int
    var latencyMs: Int
    var ttftMs: Int
    var reasoningEffort: String?
    var finishReason: String?
    var costUsd: Double
    var alias: String?
    var requestId: String?
    var tokenBreakdown: Breakdown?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, account, model, stream, status, error
        case upstreamModel = "upstream_model"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedTokens = "cached_tokens"
        case totalTokens = "total_tokens"
        case latencyMs = "latency_ms"
        case ttftMs = "ttft_ms"
        case reasoningEffort = "reasoning_effort"
        case finishReason = "finish_reason"
        case costUsd = "cost_usd"
        case alias
        case requestId = "request_id"
        case tokenBreakdown = "token_breakdown"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        account = try c.decode(String.self, forKey: .account)
        model = try c.decode(String.self, forKey: .model)
        upstreamModel = try c.decodeIfPresent(String.self, forKey: .upstreamModel) ?? ""
        stream = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
        status = try c.decodeIfPresent(Int.self, forKey: .status) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedTokens = try c.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0
        ttftMs = try c.decodeIfPresent(Int.self, forKey: .ttftMs) ?? 0
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason)
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        tokenBreakdown = try c.decodeIfPresent(Breakdown.self, forKey: .tokenBreakdown)
    }

    var displayKey: String {
        if let alias, !alias.isEmpty { return alias }
        return model
    }
}

nonisolated struct HealthResponse: Decodable {
    var status: String
}

nonisolated struct AccountListResponse: Decodable {
    var accounts: [AccountView]
}

nonisolated struct AccountView: Decodable, Identifiable, Equatable {
    var name: String
    var provider: String?
    var workbuddyUid: String?
    var workbuddyNickname: String?
    var antigravityEmail: String?
    var disabled: Bool?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, provider, disabled
        case workbuddyUid = "workbuddy_uid"
        case workbuddyNickname = "workbuddy_nickname"
        case antigravityEmail = "antigravity_email"
    }
}

nonisolated struct QuotaBucket: Codable, Equatable {
    var bucketId: String?
    var displayName: String?
    var resetTime: String?
    var remainingFraction: Double?

    enum CodingKeys: String, CodingKey {
        case bucketId = "bucketId"
        case displayName = "displayName"
        case resetTime = "resetTime"
        case remainingFraction = "remainingFraction"
    }
}

nonisolated struct QuotaGroup: Codable, Equatable {
    var displayName: String?
    var buckets: [QuotaBucket]?
}

nonisolated struct QuotaAccount: Codable, Equatable {
    var name: String
    var groups: [QuotaGroup]?
    var error: String?
}

nonisolated struct QuotaResponse: Codable, Equatable {
    var accounts: [QuotaAccount]
}

nonisolated struct ModelPrice: Codable, Equatable {
    var input: Double = 0
    var output: Double = 0
    var cached: Double = 0
    var inputPeak: Double?
    var outputPeak: Double?
    var cachedPeak: Double?
    var peakWindows: [[Int]]?

    enum CodingKeys: String, CodingKey {
        case input, output, cached
        case inputPeak = "input_peak"
        case outputPeak = "output_peak"
        case cachedPeak = "cached_peak"
        case peakWindows = "peak_windows"
    }
}

nonisolated struct PricesResponse: Decodable {
    var prices: [String: ModelPrice]
}

nonisolated struct EffortLevelsResponse: Decodable {
    var levels: [String]
}

nonisolated struct ModelsDevLookup: Decodable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var efforts: [String]
    var context: Int?
    var peakInput: Double?
    var peakOutput: Double?
    var peakCacheRead: Double?

    enum CodingKeys: String, CodingKey {
        case input, output, efforts, context
        case cacheRead = "cache_read"
        case peakInput = "peak_input"
        case peakOutput = "peak_output"
        case peakCacheRead = "peak_cache_read"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Double.self, forKey: .input)
        output = try c.decodeIfPresent(Double.self, forKey: .output)
        cacheRead = try c.decodeIfPresent(Double.self, forKey: .cacheRead)
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
        context = try c.decodeIfPresent(Int.self, forKey: .context)
        peakInput = try c.decodeIfPresent(Double.self, forKey: .peakInput)
        peakOutput = try c.decodeIfPresent(Double.self, forKey: .peakOutput)
        peakCacheRead = try c.decodeIfPresent(Double.self, forKey: .peakCacheRead)
    }
}

nonisolated struct ProviderProbeResponse: Decodable {
    var models: [String]
    var entries: [UpstreamCatalogModel]?
}

nonisolated struct UpstreamCatalogModel: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String?
    var contextLength: Int?
    var efforts: [String]?
    var thinking: ThinkingShape?

    enum CodingKeys: String, CodingKey {
        case id, efforts, thinking
        case displayName = "display_name"
        case contextLength = "context_length"
    }
}

nonisolated struct ThinkingShape: Codable, Equatable {
    var levels: [String]?
    var min: Int?
    var max: Int?
    var zeroAllowed: Bool?
    var dynamicAllowed: Bool?

    enum CodingKeys: String, CodingKey {
        case levels, min, max
        case zeroAllowed = "zero-allowed"
        case dynamicAllowed = "dynamic-allowed"
    }

    init(levels: [String]? = nil, min: Int? = nil, max: Int? = nil,
         zeroAllowed: Bool? = nil, dynamicAllowed: Bool? = nil) {
        self.levels = levels
        self.min = min
        self.max = max
        self.zeroAllowed = zeroAllowed
        self.dynamicAllowed = dynamicAllowed
    }
}

nonisolated struct ZoneModelsResponse: Decodable {
    var models: [UpstreamCatalogModel]
}

nonisolated struct OAuthStartResponse: Decodable {
    var session: String
    var url: String
}

nonisolated struct OAuthStatusResponse: Decodable {
    var done: Bool
    var success: Bool
    var error: String?
}

nonisolated struct WorkbuddyLocalResponse: Decodable {
    var found: Bool
    var source: String?
    var uid: String?
    var nickname: String?
    var authJson: String?
    var searched: [String]?

    enum CodingKeys: String, CodingKey {
        case found, source, uid, nickname, searched
        case authJson = "auth_json"
    }
}

nonisolated struct WorkbuddyAccountStatus: Decodable, Identifiable, Equatable {
    var uid: String
    var nickname: String?
    var credits: Int
    var cooling: Bool
    var coolRemainingSec: Int?
    var reason: String?

    var id: String { uid }

    enum CodingKeys: String, CodingKey {
        case uid, nickname, credits, cooling, reason
        case coolRemainingSec = "cool_remaining_sec"
    }
}

nonisolated struct WorkbuddyStatusResponse: Decodable {
    var accounts: [WorkbuddyAccountStatus]
    var healthy: Int
    var cooling: Int
    var disabled: Int
}

nonisolated struct AntigravityAccountStatus: Decodable, Identifiable, Equatable {
    var name: String
    var expired: Bool?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, expired
    }
}

nonisolated struct AntigravityStatusResponse: Decodable {
    var accounts: [AntigravityAccountStatus]
    var total: Int
    var healthy: Int
}

nonisolated struct EditAccountBody: Encodable {
    var name: String
    var newName: String?
    var key: String?
    var sessionToken: String?
    var email: String?
    var password: String?
    var disabled: Bool?

    enum CodingKeys: String, CodingKey {
        case name, key, email, password, disabled
        case newName = "new_name"
        case sessionToken = "session_token"
    }
}

nonisolated struct WorkbuddyAddBody: Encodable {
    var authJson: String

    enum CodingKeys: String, CodingKey {
        case authJson = "auth_json"
    }
}

nonisolated struct AntigravityAddBody: Encodable {
    var session: String
    var callback: String
}

nonisolated struct ProviderModelDef: Codable, Equatable {
    var name: String
    var alias: String?
    var displayName: String?
    var maxContextLength: Int?
    var thinking: ThinkingShape?
    var extras: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case name, alias, thinking
        case displayName = "display-name"
        case maxContextLength = "max-context-length"
    }

    init(name: String, alias: String? = nil, displayName: String? = nil,
         maxContextLength: Int? = nil, thinking: ThinkingShape? = nil,
         extras: [String: JSONValue] = [:]) {
        self.name = name
        self.alias = alias
        self.displayName = displayName
        self.maxContextLength = maxContextLength
        self.thinking = thinking
        self.extras = extras
    }

    private static let knownKeys: Set<String> = ["name", "alias", "display-name", "max-context-length", "thinking"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        name = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("name")) ?? ""
        let rawAlias = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("alias"))
        alias = (rawAlias?.isEmpty ?? false) ? nil : rawAlias
        displayName = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("display-name"))
        maxContextLength = try container.decodeIfPresent(Int.self, forKey: DynamicCodingKey("max-context-length"))
        thinking = try container.decodeIfPresent(ThinkingShape.self, forKey: DynamicCodingKey("thinking"))
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extras = extras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(name, forKey: DynamicCodingKey("name"))
        if let alias, !alias.isEmpty {
            try container.encode(alias, forKey: DynamicCodingKey("alias"))
        }
        if let displayName {
            try container.encode(displayName, forKey: DynamicCodingKey("display-name"))
        }
        if let maxContextLength {
            try container.encode(maxContextLength, forKey: DynamicCodingKey("max-context-length"))
        }
        if let thinking {
            try container.encode(thinking, forKey: DynamicCodingKey("thinking"))
        }
        for (key, value) in extras {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}

nonisolated struct ApiKeyEntry: Codable, Equatable {
    var apiKey: String
    var proxyUrl: String?
    var extras: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case apiKey = "api-key"
        case proxyUrl = "proxy-url"
    }

    init(apiKey: String, proxyUrl: String? = nil, extras: [String: JSONValue] = [:]) {
        self.apiKey = apiKey
        self.proxyUrl = proxyUrl
        self.extras = extras
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        apiKey = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("api-key")) ?? ""
        let rawProxy = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("proxy-url"))
        proxyUrl = (rawProxy?.isEmpty ?? false) ? nil : rawProxy
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where key.stringValue != "api-key" && key.stringValue != "proxy-url" {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extras = extras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(apiKey, forKey: DynamicCodingKey("api-key"))
        if let proxyUrl, !proxyUrl.isEmpty {
            try container.encode(proxyUrl, forKey: DynamicCodingKey("proxy-url"))
        }
        for (key, value) in extras {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}

nonisolated struct ProviderEntry: Codable, Equatable, Identifiable {
    var name: String
    var disabled: Bool?
    var kind: String?
    var baseUrl: String?
    var project: String?
    var apiKeyEntries: [ApiKeyEntry]
    var models: [ProviderModelDef]
    var extras: [String: JSONValue] = [:]

    var id: String { name }

    static let managedKinds = ["workbuddy", "antigravity"]

    var isManaged: Bool { kind.map(Self.managedKinds.contains) ?? false }

    init(name: String, disabled: Bool? = nil, kind: String? = nil, baseUrl: String? = nil,
         project: String? = nil, apiKeyEntries: [ApiKeyEntry] = [], models: [ProviderModelDef] = [],
         extras: [String: JSONValue] = [:]) {
        self.name = name
        self.disabled = disabled
        self.kind = kind
        self.baseUrl = baseUrl
        self.project = project
        self.apiKeyEntries = apiKeyEntries
        self.models = models
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "name", "disabled", "kind", "base-url", "project", "api-key-entries", "models",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        name = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("name")) ?? ""
        disabled = try container.decodeIfPresent(Bool.self, forKey: DynamicCodingKey("disabled"))
        kind = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("kind"))
        baseUrl = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("base-url"))
        project = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("project"))
        apiKeyEntries = try container.decodeIfPresent([ApiKeyEntry].self, forKey: DynamicCodingKey("api-key-entries")) ?? []
        models = try container.decodeIfPresent([ProviderModelDef].self, forKey: DynamicCodingKey("models")) ?? []
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extras = extras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(name, forKey: DynamicCodingKey("name"))
        if let disabled {
            try container.encode(disabled, forKey: DynamicCodingKey("disabled"))
        }
        if let kind {
            try container.encode(kind, forKey: DynamicCodingKey("kind"))
        }
        try container.encode(baseUrl ?? "", forKey: DynamicCodingKey("base-url"))
        if let project {
            try container.encode(project, forKey: DynamicCodingKey("project"))
        }
        try container.encode(apiKeyEntries, forKey: DynamicCodingKey("api-key-entries"))
        try container.encode(models, forKey: DynamicCodingKey("models"))
        for (key, value) in extras {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }

    var usableKind: String {
        if let kind, Self.managedKinds.contains(kind) { return kind }
        return kind == "responses" ? "responses" : "openai"
    }
}
