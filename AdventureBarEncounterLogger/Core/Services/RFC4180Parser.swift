import Foundation

public struct ParsedCSVRecord: Equatable {
    public var rowNumber: Int
    public var fields: [String]
    public var structuralError: String?

    public init(rowNumber: Int, fields: [String], structuralError: String? = nil) {
        self.rowNumber = rowNumber
        self.fields = fields
        self.structuralError = structuralError
    }
}

public enum RFC4180ParserError: LocalizedError, Equatable {
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "The CSV file is not valid UTF-8."
        }
    }
}

public enum RFC4180Parser {
    public static func parse(data: Data) throws -> [ParsedCSVRecord] {
        guard var text = String(data: data, encoding: .utf8) else { throw RFC4180ParserError.invalidUTF8 }
        if text.unicodeScalars.first?.value == 0xFEFF { text.removeFirst() }
        return parse(text: text)
    }

    public static func parse(text: String) -> [ParsedCSVRecord] {
        let characters = Array(text)
        var records: [ParsedCSVRecord] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var justClosedQuote = false
        var rowError: String?
        var rowStartLine = 1
        var currentLine = 1
        var index = 0

        func finishRecord() {
            fields.append(field)
            if !(fields.count == 1 && fields[0].isEmpty && rowError == nil) {
                records.append(ParsedCSVRecord(rowNumber: rowStartLine, fields: fields, structuralError: rowError))
            }
            fields = []
            field = ""
            rowError = nil
            justClosedQuote = false
            rowStartLine = currentLine
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    justClosedQuote = true
                    index += 1
                    continue
                }
                field.append(character)
                if character == "\n" { currentLine += 1 }
                index += 1
                continue
            }

            if justClosedQuote {
                if character == "," {
                    fields.append(field)
                    field = ""
                    justClosedQuote = false
                    index += 1
                    continue
                }
                if character == "\r" || character == "\n" {
                    if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                    currentLine += 1
                    index += 1
                    finishRecord()
                    rowStartLine = currentLine
                    continue
                }
                rowError = rowError ?? "Unexpected character after a closing quote."
                field.append(character)
                justClosedQuote = false
                index += 1
                continue
            }

            switch character {
            case "\"":
                if field.isEmpty {
                    inQuotes = true
                } else {
                    rowError = rowError ?? "Quote found in an unquoted field."
                    field.append(character)
                }
                index += 1
            case ",":
                fields.append(field)
                field = ""
                index += 1
            case "\r", "\n":
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                currentLine += 1
                index += 1
                finishRecord()
                rowStartLine = currentLine
            default:
                field.append(character)
                index += 1
            }
        }

        if inQuotes { rowError = rowError ?? "Quoted field was not closed before the end of the file." }
        if !field.isEmpty || !fields.isEmpty || justClosedQuote || rowError != nil {
            finishRecord()
        }
        return records
    }
}

