import Foundation

/// When a watcher runs. Polling every N seconds is right for "watch my screen"; it is the
/// wrong shape for "every weekday at 9am" — which is most of what people actually want
/// automated. Ported from OpenWorker's cron automations, with the timezone rule that
/// matters on a laptop: everything is evaluated in the machine's *local* time, so a
/// 9am job stays 9am after you fly somewhere.
enum WatcherSchedule: Codable, Equatable {
    /// Every N seconds (the original behavior).
    case interval(seconds: Int)
    /// Every day at a local wall-clock time.
    case daily(hour: Int, minute: Int)
    /// Monday–Friday at a local wall-clock time.
    case weekdays(hour: Int, minute: Int)
    /// On the given weekdays (1 = Sunday … 7 = Saturday, `Calendar` convention).
    case weekly(days: [Int], hour: Int, minute: Int)
    /// On a day of the month (clamped to the last day for short months).
    case monthly(day: Int, hour: Int, minute: Int)
    /// A standard 5-field cron expression, for people who already think in cron.
    case cron(expression: String)
    /// Exactly once, then the watcher disables itself.
    case once(at: Date)

    // MARK: - Next fire

    /// The next moment this schedule is due after `date`, or nil when it never fires again.
    /// Everything goes through `Calendar`, so DST shifts and short months are handled for us.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case let .interval(seconds):
            return date.addingTimeInterval(TimeInterval(max(WatcherAgent.minLoopIntervalSeconds, seconds)))
        case let .once(at):
            return at > date ? at : nil
        case let .daily(hour, minute):
            return next(matching: DateComponents(hour: hour, minute: minute), after: date, calendar: calendar)
        case let .weekdays(hour, minute):
            return earliest(
                (2...6).map { DateComponents(hour: hour, minute: minute, weekday: $0) },
                after: date, calendar: calendar)
        case let .weekly(days, hour, minute):
            let wanted = days.isEmpty ? [2] : days
            return earliest(
                wanted.map { DateComponents(hour: hour, minute: minute, weekday: $0) },
                after: date, calendar: calendar)
        case let .monthly(day, hour, minute):
            // `.nextTime` clamps "the 31st" to the last day of a short month rather than skipping it.
            return next(
                matching: DateComponents(day: day, hour: hour, minute: minute), after: date,
                calendar: calendar)
        case let .cron(expression):
            return WatcherCron.parse(expression)?.nextFireDate(after: date, calendar: calendar)
        }
    }

    private func next(matching components: DateComponents, after date: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime,
            repeatedTimePolicy: .first, direction: .forward)
    }

    private func earliest(_ candidates: [DateComponents], after date: Date, calendar: Calendar) -> Date? {
        candidates.compactMap { next(matching: $0, after: date, calendar: calendar) }.min()
    }

    // MARK: - Display

    var humanLabel: String {
        switch self {
        case let .interval(seconds):
            return seconds >= 3600
                ? "Every \(seconds / 3600)h"
                : (seconds >= 60 ? "Every \(seconds / 60) min" : "Every \(seconds)s")
        case let .daily(h, m):
            return "Every day at \(Self.clock(h, m))"
        case let .weekdays(h, m):
            return "Weekdays at \(Self.clock(h, m))"
        case let .weekly(days, h, m):
            let names = days.sorted().map { Self.weekdayName($0) }.joined(separator: ", ")
            return "\(names.isEmpty ? "Weekly" : names) at \(Self.clock(h, m))"
        case let .monthly(d, h, m):
            return "Day \(d) of each month at \(Self.clock(h, m))"
        case let .cron(expression):
            return "cron: \(expression)"
        case let .once(at):
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return "Once on \(fmt.string(from: at))"
        }
    }

    /// True when this schedule fires at wall-clock times (and so can be *missed* while the
    /// Mac is asleep — the catch-up case).
    var isWallClock: Bool {
        switch self {
        case .interval: return false
        default: return true
        }
    }

    static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "?"
    }

    // MARK: - Codable (tagged, so associated values round-trip)

    private enum CodingKeys: String, CodingKey {
        case type, seconds, hour, minute, days, day, expression, at
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .interval(seconds):
            try c.encode("interval", forKey: .type)
            try c.encode(seconds, forKey: .seconds)
        case let .daily(hour, minute):
            try c.encode("daily", forKey: .type)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
        case let .weekdays(hour, minute):
            try c.encode("weekdays", forKey: .type)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
        case let .weekly(days, hour, minute):
            try c.encode("weekly", forKey: .type)
            try c.encode(days, forKey: .days)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
        case let .monthly(day, hour, minute):
            try c.encode("monthly", forKey: .type)
            try c.encode(day, forKey: .day)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
        case let .cron(expression):
            try c.encode("cron", forKey: .type)
            try c.encode(expression, forKey: .expression)
        case let .once(at):
            try c.encode("once", forKey: .type)
            try c.encode(at, forKey: .at)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hour = (try? c.decode(Int.self, forKey: .hour)) ?? 9
        let minute = (try? c.decode(Int.self, forKey: .minute)) ?? 0
        switch try c.decode(String.self, forKey: .type) {
        case "daily":
            self = .daily(hour: hour, minute: minute)
        case "weekdays":
            self = .weekdays(hour: hour, minute: minute)
        case "weekly":
            self = .weekly(
                days: (try? c.decode([Int].self, forKey: .days)) ?? [2], hour: hour, minute: minute)
        case "monthly":
            self = .monthly(
                day: (try? c.decode(Int.self, forKey: .day)) ?? 1, hour: hour, minute: minute)
        case "cron":
            self = .cron(expression: (try? c.decode(String.self, forKey: .expression)) ?? "0 9 * * *")
        case "once":
            self = .once(at: (try? c.decode(Date.self, forKey: .at)) ?? Date())
        default:
            self = .interval(
                seconds: (try? c.decode(Int.self, forKey: .seconds))
                    ?? WatcherAgent.defaultLoopIntervalSeconds)
        }
    }
}

/// A minimal 5-field cron matcher (minute hour day-of-month month day-of-week).
/// Supports `*`, numbers, `a,b`, `a-b` and `*/n` — the forms people actually write.
/// Anything it cannot parse is rejected up front rather than silently mis-firing.
struct WatcherCron: Equatable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>

    static func parse(_ expression: String) -> WatcherCron? {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5,
            let minutes = field(fields[0], range: 0...59),
            let hours = field(fields[1], range: 0...23),
            let days = field(fields[2], range: 1...31),
            let months = field(fields[3], range: 1...12),
            let weekdays = field(fields[4], range: 0...7)
        else { return nil }
        // cron allows both 0 and 7 for Sunday.
        var normalizedWeekdays = weekdays
        if normalizedWeekdays.contains(7) { normalizedWeekdays.insert(0) }
        return WatcherCron(
            minutes: minutes, hours: hours, days: days, months: months, weekdays: normalizedWeekdays)
    }

    /// Day-by-day scan (a year at most), then the sorted hour × minute slots inside a
    /// matching day — cheap enough that we never need clever cron arithmetic.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        let slots = hours.sorted().flatMap { hour in minutes.sorted().map { (hour, $0) } }
        guard !slots.isEmpty else { return nil }
        guard var day = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: date))
        else { return nil }

        for _ in 0...366 {
            let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
            if let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
                months.contains(month), dayMatches(day: dayOfMonth, weekday: weekday - 1)
            {
                for (hour, minute) in slots {
                    if let candidate = calendar.date(
                        bySettingHour: hour, minute: minute, second: 0, of: day),
                        candidate > date
                    {
                        return candidate
                    }
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = nextDay
        }
        return nil
    }

    /// Standard cron: when both day-of-month and day-of-week are restricted, either matching
    /// fires. When only one is restricted, that one decides.
    private func dayMatches(day: Int, weekday: Int) -> Bool {
        let dayRestricted = days.count < 31
        let weekdayRestricted = weekdays.count < 8
        switch (dayRestricted, weekdayRestricted) {
        case (false, false): return true
        case (true, false): return days.contains(day)
        case (false, true): return weekdays.contains(weekday)
        case (true, true): return days.contains(day) || weekdays.contains(weekday)
        }
    }

    private static func field(_ raw: String, range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let piece = String(part)
            // "*/n" or "a-b/n"
            let stepSplit = piece.split(separator: "/", omittingEmptySubsequences: false)
            guard stepSplit.count <= 2 else { return nil }
            let step: Int
            if stepSplit.count == 2 {
                guard let value = Int(stepSplit[1]), value > 0 else { return nil }
                step = value
            } else {
                step = 1
            }
            let base = String(stepSplit[0])
            let bounds: ClosedRange<Int>
            if base == "*" {
                bounds = range
            } else if base.contains("-") {
                let ends = base.split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count == 2, let lower = Int(ends[0]), let upper = Int(ends[1]),
                    lower <= upper, range.contains(lower), range.contains(upper)
                else { return nil }
                bounds = lower...upper
            } else {
                guard let value = Int(base), range.contains(value) else { return nil }
                bounds = value...value
            }
            for value in stride(from: bounds.lowerBound, through: bounds.upperBound, by: step) {
                out.insert(value)
            }
        }
        return out.isEmpty ? nil : out
    }
}
