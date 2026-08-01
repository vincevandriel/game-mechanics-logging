import Foundation

public enum JSONCoding {
    public static func makeEncoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Coding.string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ISO8601Coding.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(value)")
            }
            return date
        }
        return decoder
    }
}

public enum ISO8601Coding {
    public static func string(from date: Date) -> String {
        var seconds = floor(date.timeIntervalSince1970)
        var nanoseconds = Int64(((date.timeIntervalSince1970 - seconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            seconds += 1
            nanoseconds = 0
        }
        let wholeSecond = Date(timeIntervalSince1970: seconds)
        let fraction = String(format: "%09lld", nanoseconds)
        return "\(wholeSecondFormatter.string(from: wholeSecond)).\(fraction)Z"
    }

    public static func date(from string: String) -> Date? {
        // App exports use UTC with exactly nine fractional digits. Parse that
        // representation manually so Date's sub-millisecond value round-trips;
        // ISO8601DateFormatter formats only milliseconds on some Apple OS builds.
        if string.hasSuffix("Z"),
           let dot = string.lastIndex(of: "."),
           let wholeSecond = wholeSecondFormatter.date(from: String(string[..<dot])) {
            let fractionStart = string.index(after: dot)
            let fractionEnd = string.index(before: string.endIndex)
            let fraction = String(string[fractionStart..<fractionEnd])
            if !fraction.isEmpty,
               fraction.count <= 9,
               fraction.allSatisfy(\.isNumber),
               let value = Int64(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) {
                return wholeSecond.addingTimeInterval(Double(value) / 1_000_000_000)
            }
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: string)
    }

    private static var wholeSecondFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }
}
