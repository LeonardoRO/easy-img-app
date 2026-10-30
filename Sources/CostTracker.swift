import Foundation

/// Tokens (and generated images) one request used, normalized across providers.
struct TokenUsage {
    /// Input tokens billed at the normal rate (excludes cache reads and writes).
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Output tokens, including reasoning/thinking tokens.
    var output = 0
    var images = 0
}

struct UsageRecord: Codable {
    var date: Date
    var provider: String
    var model: String
    /// "chat" or "image".
    var kind: String
    var inputTokens: Int
    var cachedTokens: Int
    var outputTokens: Int
    var images: Int
    /// nil when no price is known for the model.
    var cost: Double?
}

/// Price per 1M tokens in USD (and per image for image models).
struct ModelPrice: Codable {
    /// Exact model ID, or a prefix that matches a family of IDs (the longest match wins).
    var model: String
    var input: Double
    var output: Double
    /// Cache-read price; defaults to the input price when nil.
    var cachedInput: Double?
    var perImage: Double?
}

/// Estimates spending from the usage each provider reports, keeps a local history and enforces the monthly limit.
final class CostTracker {
    static let shared = CostTracker()
    static let didChange = Notification.Name("EasyImgCostsDidChange")

    enum LimitState { case ok, warning, reached }

    private(set) var records: [UsageRecord] = []
    var prices: [ModelPrice] {
        didSet { save(prices, to: pricesFile); notify() }
    }

    private let directory: URL
    private var recordsFile: URL { directory.appendingPathComponent("usage.json") }
    private var pricesFile: URL { directory.appendingPathComponent("prices.json") }
    private static let limitEnabledKey = "SpendingLimitEnabled"
    private static let limitKey = "MonthlySpendingLimit"
    private static let maxRecords = 5000

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Easy Img", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prices = (try? JSONDecoder().decode([ModelPrice].self, from: Data(contentsOf: directory.appendingPathComponent("prices.json"))))
            ?? DefaultPrices.all
        records = (try? JSONDecoder.withDates.decode([UsageRecord].self, from: Data(contentsOf: recordsFile))) ?? []
    }

    // MARK: Limit

    var limitEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.limitEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.limitEnabledKey); notify() }
    }

    var monthlyLimit: Double {
        get { UserDefaults.standard.object(forKey: Self.limitKey) as? Double ?? 10 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.limitKey); notify() }
    }

    var limitState: LimitState {
        guard limitEnabled else { return .ok }
        let spent = monthTotal
        if spent >= monthlyLimit { return .reached }
        return spent >= monthlyLimit * 0.8 ? .warning : .ok
    }

    // MARK: Totals

    var monthTotal: Double { total(since: Calendar.current.dateInterval(of: .month, for: Date())!.start) }
    var todayTotal: Double { total(since: Calendar.current.startOfDay(for: Date())) }

    func total(since start: Date) -> Double {
        records.reduce(0) { $1.date >= start ? $0 + ($1.cost ?? 0) : $0 }
    }

    /// Requests this month whose model has no price, so the total is incomplete.
    var unpricedThisMonth: Int {
        let start = Calendar.current.dateInterval(of: .month, for: Date())!.start
        return records.filter { $0.date >= start && $0.cost == nil }.count
    }

    // MARK: Recording

    func price(for model: String) -> ModelPrice? {
        if let exact = prices.first(where: { $0.model == model }) { return exact }
        return prices.filter { model.hasPrefix($0.model) }.max { $0.model.count < $1.model.count }
    }

    func cost(of usage: TokenUsage, model: String) -> Double? {
        guard let price = price(for: model) else { return nil }
        let cacheRead = price.cachedInput ?? price.input
        let tokens = Double(usage.input) * price.input
            + Double(usage.cacheRead) * cacheRead
            + Double(usage.cacheWrite) * price.input * 1.25
            + Double(usage.output) * price.output
        return tokens / 1_000_000 + Double(usage.images) * (price.perImage ?? 0)
    }

    @discardableResult
    func record(provider: String, model: String, kind: String, usage: TokenUsage) -> UsageRecord {
        let record = UsageRecord(date: Date(), provider: provider, model: model, kind: kind,
                                 inputTokens: usage.input + usage.cacheWrite, cachedTokens: usage.cacheRead,
                                 outputTokens: usage.output, images: usage.images,
                                 cost: cost(of: usage, model: model))
        records.append(record)
        if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
        save(records, to: recordsFile)
        notify()
        return record
    }

    func clearHistory() {
        records = []
        save(records, to: recordsFile)
        notify()
    }

    func resetPrices() {
        prices = DefaultPrices.all
    }

    private func save<T: Encodable>(_ value: T, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(value).write(to: file, options: .atomic)
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

private extension JSONDecoder {
    static var withDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Double {
    /// "$0.0123" for small amounts, "$1.23" otherwise.
    var dollars: String {
        String(format: self != 0 && abs(self) < 0.1 ? "$%.4f" : "$%.2f", self)
    }
}
