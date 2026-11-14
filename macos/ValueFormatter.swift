import Foundation

/// Turns PostgreSQL's text output into friendlier display values: booleans
/// as true/false and dates/timestamps in the user's locale (timestamptz in
/// the local time zone). Raw values are kept for sorting, copying and
/// queries; this is display only.
struct ValueFormatter {
    var locale = Locale.current
    var timeZone = TimeZone.current

    enum Kind { case boolean, date, timestamp, timestampWithZone, booleanArray, other }

    static func kind(of type: String?) -> Kind {
        switch type {
        case "bool": return .boolean
        case "_bool": return .booleanArray
        case "date": return .date
        case "timestamp": return .timestamp
        case "timestamptz": return .timestampWithZone
        default: return .other
        }
    }

    /// Text shown in the results grid.
    func display(_ raw: String, type: String?) -> String {
        switch Self.kind(of: type) {
        case .boolean:
            return raw == "t" ? "true" : raw == "f" ? "false" : raw
        case .booleanArray:
            guard raw.hasPrefix("{") else { return raw }
            return raw.split(separator: ",", omittingEmptySubsequences: false).map { part -> String in
                var text = String(part)
                let open = text.hasPrefix("{"), close = text.hasSuffix("}")
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                text = text == "t" ? "true" : text == "f" ? "false" : text
                return (open ? "{" : "") + text + (close ? "}" : "")
            }.joined(separator: ",")
        case .date:
            guard let date = parse(raw, hasTime: false, hasZone: false) else { return raw }
            return formatter(date: .short, time: .none).string(from: date)
        case .timestamp:
            guard let date = parse(raw, hasTime: true, hasZone: false) else { return raw }
            return formatter(date: .short, time: .medium).string(from: date)
        case .timestampWithZone:
            guard let date = parse(raw, hasTime: true, hasZone: true) else { return raw }
            return formatter(date: .short, time: .medium).string(from: date)
        case .other:
            return raw
        }
    }

    /// Value for the details drawer: a longer, more readable form plus the
    /// original text when they differ (so microseconds and offsets are not
    /// lost).
    func detail(_ raw: String, type: String?) -> (value: String, original: String?) {
        let kind = Self.kind(of: type)
        let value: String
        switch kind {
        case .date:
            guard let date = parse(raw, hasTime: false, hasZone: false) else { return (raw, nil) }
            value = formatter(date: .full, time: .none).string(from: date)
        case .timestamp:
            guard let date = parse(raw, hasTime: true, hasZone: false) else { return (raw, nil) }
            value = formatter(date: .long, time: .medium).string(from: date)
        case .timestampWithZone:
            guard let date = parse(raw, hasTime: true, hasZone: true) else { return (raw, nil) }
            let zone = timeZone.localizedName(for: .shortStandard, locale: locale) ?? timeZone.identifier
            value = formatter(date: .long, time: .medium).string(from: date) + " (\(zone))"
        default:
            return (display(raw, type: type), nil)
        }
        return (value, value == raw ? nil : raw)
    }

    private func formatter(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let key = "\(locale.identifier)|\(timeZone.identifier)|\(date.rawValue)|\(time.rawValue)"
        if let cached = Self.cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = date
        formatter.timeStyle = time
        Self.cache[key] = formatter
        return formatter
    }

    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    private static let pattern = try! NSRegularExpression(pattern:
        #"^(\d{4,})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2})(\.\d+)?)?(?:([+-])(\d{2})(?::?(\d{2}))?(?::?(\d{2}))?)?$"#)

    /// Parses ISO-style output (DateStyle ISO). Infinity, BC dates and other
    /// styles return nil so the raw value is shown untouched.
    func parse(_ raw: String, hasTime: Bool, hasZone: Bool) -> Date? {
        let text = raw as NSString
        guard let match = Self.pattern.firstMatch(in: raw, range: NSRange(location: 0, length: text.length)) else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }
        if hasTime != (group(4) != nil) { return nil }
        if hasZone != (group(8) != nil) { return nil }
        var components = DateComponents()
        components.year = Int(group(1)!)
        components.month = Int(group(2)!)
        components.day = Int(group(3)!)
        components.hour = group(4).flatMap { Int($0) } ?? 0
        components.minute = group(5).flatMap { Int($0) } ?? 0
        components.second = group(6).flatMap { Int($0) } ?? 0
        if let fraction = group(7), let value = Double("0" + fraction) { components.nanosecond = Int(value * 1_000_000_000) }
        var calendar = Calendar(identifier: .gregorian)
        if hasZone, let sign = group(8), let hours = Int(group(9) ?? "") {
            let seconds = hours * 3600 + (Int(group(10) ?? "") ?? 0) * 60 + (Int(group(11) ?? "") ?? 0)
            calendar.timeZone = TimeZone(secondsFromGMT: sign == "-" ? -seconds : seconds) ?? timeZone
        } else {
            // Dates and timestamps without zone are shown as written.
            calendar.timeZone = timeZone
        }
        return calendar.date(from: components)
    }
}
