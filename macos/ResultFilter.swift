import Foundation

/// Client-side filters for the results grid. Several filters combine with
/// AND; each one targets a column by name so it survives re-running the
/// query.
enum FilterOperator: String, CaseIterable {
    case contains, notContains, equals, notEquals, startsWith, endsWith, greaterThan, lessThan, isNull, isNotNull

    var title: String {
        switch self {
        case .contains: return "contém"
        case .notContains: return "não contém"
        case .equals: return "é igual a"
        case .notEquals: return "é diferente de"
        case .startsWith: return "começa com"
        case .endsWith: return "termina com"
        case .greaterThan: return "maior que"
        case .lessThan: return "menor que"
        case .isNull: return "é NULL"
        case .isNotNull: return "não é NULL"
        }
    }

    var needsValue: Bool { self != .isNull && self != .isNotNull }
}

struct ResultFilter: Equatable {
    var column: String
    var op: FilterOperator = .contains
    var value = ""

    /// A filter without a value (still being typed) does not hide rows.
    var isActive: Bool { !op.needsValue || !value.trimmingCharacters(in: .whitespaces).isEmpty }

    /// `raw` is the value as returned by PostgreSQL; `display` is what the
    /// grid shows (e.g. `true` for `t`). Text operators match either.
    func matches(raw: String, display: String) -> Bool {
        let isNull = raw == "NULL"
        switch op {
        case .isNull: return isNull
        case .isNotNull: return !isNull
        default: break
        }
        let needle = value.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        let candidates = raw == display ? [raw] : [raw, display]
        func any(_ test: (String) -> Bool) -> Bool { candidates.contains(where: test) }
        switch op {
        case .contains: return any { $0.localizedCaseInsensitiveContains(needle) }
        case .notContains: return !any { $0.localizedCaseInsensitiveContains(needle) }
        case .equals: return any { $0.caseInsensitiveCompare(needle) == .orderedSame }
        case .notEquals: return !any { $0.caseInsensitiveCompare(needle) == .orderedSame }
        case .startsWith: return any { $0.lowercased().hasPrefix(needle.lowercased()) }
        case .endsWith: return any { $0.lowercased().hasSuffix(needle.lowercased()) }
        case .greaterThan: return !isNull && Self.compare(raw, needle) == .orderedDescending
        case .lessThan: return !isNull && Self.compare(raw, needle) == .orderedAscending
        case .isNull, .isNotNull: return true
        }
    }

    /// Numbers compare numerically; anything else (ISO dates included)
    /// compares as text, which orders ISO timestamps correctly.
    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        if let a = Double(left), let b = Double(right) { return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame }
        return left.localizedStandardCompare(right)
    }
}

extension Array where Element == ResultFilter {
    /// Indexes of the rows that pass every active filter.
    func apply(headers: [String], rows: [[String]], display: (_ raw: String, _ column: Int) -> String) -> [Int] {
        let active: [(Int, ResultFilter)] = compactMap { filter in
            guard filter.isActive, let column = headers.firstIndex(of: filter.column) else { return nil }
            return (column, filter)
        }
        guard !active.isEmpty else { return Array<Int>(rows.indices) }
        return rows.indices.filter { index in
            active.allSatisfy { column, filter in
                let raw = column < rows[index].count ? rows[index][column] : "NULL"
                return filter.matches(raw: raw, display: display(raw, column))
            }
        }
    }
}

/// Compact approximate counts for the sidebar: 950, 12 mil, 1,2 mi.
enum RowEstimate {
    static func short(_ count: Int64, locale: Locale = .current) -> String {
        guard count >= 0 else { return "?" }
        if count < 1000 { return "\(count)" }
        return "~" + Int(count).formatted(.number.notation(.compactName).precision(.significantDigits(2)).locale(locale))
    }

    static func long(_ count: Int64, locale: Locale = .current) -> String {
        guard count >= 0 else { return "Sem estatísticas ainda (rode ANALYZE)" }
        return "≈ " + Int(count).formatted(.number.locale(locale)) + " linhas (estimativa do PostgreSQL)"
    }
}
