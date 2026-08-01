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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: string)
    }
}

