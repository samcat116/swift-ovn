import NIOCore

/// The two members of a JSON-RPC message that decide where it goes: `method`
/// and `id`.
struct JSONRPCFrameEnvelope: Equatable {
    /// How the frame's `id` member appeared on the wire.
    enum Identifier: Equatable {
        /// Absent, or present as JSON `null`. JSON-RPC marks notifications
        /// this way, so a frame with a `method` and this identifier expects no
        /// reply.
        case absent
        /// A string or integer id, which can be correlated with a pending
        /// request.
        case value(JSONRPCIdentifier)
        /// Present but not a string or integer (a float, an object, a boolean,
        /// …), or a string whose escape sequences this scanner does not expand.
        /// No request this library issues carries such an id, so a response
        /// bearing one cannot be correlated.
        case unsupported
    }

    /// The `method` member when present and a JSON string.
    ///
    /// Escape sequences are *not* expanded: the value is only used to decide
    /// whether the frame is a request/notification, compared against `echo`,
    /// and logged. The notification path re-decodes the frame with
    /// `JSONDecoder`, which unescapes properly, so the published method name
    /// is always correct.
    var method: String?
    var identifier: Identifier = .absent
}

/// Finds the `method` and `id` members of a JSON-RPC frame without parsing the
/// rest of it.
///
/// Routing an inbound message only needs those two members, but they sit in a
/// document whose `params`/`result` payload is frequently multi-megabyte —
/// Southbound `Logical_Flow` monitor updates in particular. Parsing the whole
/// document just to read them (what the old `JSONSerialization` pre-pass did)
/// doubled the parse cost of every inbound message, since the matched
/// pending request or notification then decodes the same bytes again. This
/// scanner is a single allocation-free pass that skips over payload values
/// instead of building them, and stops as soon as both members are found.
enum JSONRPCFrameScanner {
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")

    /// Scans the top level of a JSON object for `method` and `id`.
    ///
    /// Returns nil when `buffer` is not a JSON object or is malformed badly
    /// enough that the top-level members cannot be walked. Members other than
    /// `method` and `id` are skipped without being validated, so a frame whose
    /// *payload* is malformed still scans — the subsequent full decode is what
    /// rejects it.
    static func scanEnvelope(_ buffer: ByteBuffer) -> JSONRPCFrameEnvelope? {
        let view = buffer.readableBytesView
        var cursor = view.startIndex
        var envelope = JSONRPCFrameEnvelope()
        var foundMethod = false
        var foundIdentifier = false

        skipWhitespace(view, &cursor)
        guard cursor < view.endIndex, view[cursor] == openBrace else { return nil }
        cursor = view.index(after: cursor)

        while true {
            skipWhitespace(view, &cursor)
            guard cursor < view.endIndex else { return nil }
            if view[cursor] == closeBrace { return envelope }

            guard view[cursor] == quote,
                  let key = readString(view, &cursor) else { return nil }
            skipWhitespace(view, &cursor)
            guard cursor < view.endIndex, view[cursor] == colon else { return nil }
            cursor = view.index(after: cursor)
            skipWhitespace(view, &cursor)
            guard cursor < view.endIndex else { return nil }

            if key.value == "method" && !key.containsEscapes {
                if view[cursor] == quote, let method = readString(view, &cursor) {
                    envelope.method = method.value
                } else {
                    // A non-string `method` is not a method at all; skip it and
                    // treat the frame as method-less.
                    guard skipValue(view, &cursor) else { return nil }
                }
                foundMethod = true
            } else if key.value == "id" && !key.containsEscapes {
                guard let identifier = readIdentifier(view, &cursor) else { return nil }
                envelope.identifier = identifier
                foundIdentifier = true
            } else {
                guard skipValue(view, &cursor) else { return nil }
            }

            // Both members found: the rest of the document — including the
            // large payload — never has to be walked.
            if foundMethod && foundIdentifier { return envelope }

            skipWhitespace(view, &cursor)
            guard cursor < view.endIndex else { return nil }
            if view[cursor] == comma {
                cursor = view.index(after: cursor)
                continue
            }
            if view[cursor] == closeBrace { return envelope }
            return nil
        }
    }

    // MARK: - Scalars

    private struct ScannedString {
        /// The string's bytes as they appeared, with escape sequences left
        /// unexpanded.
        let value: String
        let containsEscapes: Bool
    }

    private static func skipWhitespace(_ view: ByteBufferView, _ cursor: inout ByteBufferView.Index) {
        while cursor < view.endIndex, isWhitespace(view[cursor]) {
            cursor = view.index(after: cursor)
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        return byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
    }

    /// Reads a JSON string starting at the opening quote, leaving `cursor` just
    /// past the closing quote.
    private static func readString(_ view: ByteBufferView, _ cursor: inout ByteBufferView.Index) -> ScannedString? {
        precondition(view[cursor] == quote)
        var index = view.index(after: cursor)
        let start = index
        var escaped = false
        var containsEscapes = false

        while index < view.endIndex {
            let byte = view[index]
            if escaped {
                escaped = false
            } else if byte == backslash {
                escaped = true
                containsEscapes = true
            } else if byte == quote {
                let value = String(decoding: view[start..<index], as: UTF8.self)
                cursor = view.index(after: index)
                return ScannedString(value: value, containsEscapes: containsEscapes)
            }
            index = view.index(after: index)
        }
        return nil
    }

    /// Reads the value of an `id` member, leaving `cursor` just past it.
    private static func readIdentifier(_ view: ByteBufferView, _ cursor: inout ByteBufferView.Index) -> JSONRPCFrameEnvelope.Identifier? {
        if view[cursor] == quote {
            guard let string = readString(view, &cursor) else { return nil }
            // An id whose escapes are unexpanded cannot be compared with the
            // ids this library generates; refusing to correlate it is safer
            // than matching the wrong pending request.
            return string.containsEscapes ? .unsupported : .value(.string(string.value))
        }

        let start = cursor
        guard skipValue(view, &cursor) else { return nil }
        let literal = view[start..<cursor]
        if literal.elementsEqual("null".utf8) {
            return .absent
        }
        // JSONRPCIdentifier carries only strings and Ints, so a fractional or
        // out-of-range number is not correlatable either.
        guard let integer = Int(String(decoding: literal, as: UTF8.self)) else {
            return .unsupported
        }
        return .value(.number(integer))
    }

    /// Advances `cursor` past one complete JSON value.
    private static func skipValue(_ view: ByteBufferView, _ cursor: inout ByteBufferView.Index) -> Bool {
        guard cursor < view.endIndex else { return false }

        switch view[cursor] {
        case quote:
            return readString(view, &cursor) != nil
        case openBrace, openBracket:
            var depth = 0
            var inString = false
            var escaped = false
            while cursor < view.endIndex {
                let byte = view[cursor]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == backslash {
                        escaped = true
                    } else if byte == quote {
                        inString = false
                    }
                } else {
                    switch byte {
                    case quote:
                        inString = true
                    case openBrace, openBracket:
                        depth += 1
                    case closeBrace, closeBracket:
                        depth -= 1
                    default:
                        break
                    }
                }
                cursor = view.index(after: cursor)
                if !inString && depth == 0 {
                    return true
                }
            }
            return false
        default:
            // A number, `true`, `false` or `null`: everything up to the next
            // structural byte belongs to it.
            while cursor < view.endIndex,
                  !isWhitespace(view[cursor]),
                  view[cursor] != comma,
                  view[cursor] != closeBrace,
                  view[cursor] != closeBracket {
                cursor = view.index(after: cursor)
            }
            return true
        }
    }
}
