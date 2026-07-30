import NIOCore

/// Frames a byte stream into individual JSON-RPC objects.
///
/// OVSDB (RFC 7047) streams JSON-RPC objects with no delimiters — the server may
/// concatenate several objects in a single read, or split one object across reads.
/// A newline-based framer therefore mis-frames these messages. This decoder instead
/// tracks `{`/`}` nesting depth to emit exactly one complete top-level object per
/// message, ignoring braces that appear inside JSON strings and honoring `\` escapes.
///
/// Frames are emitted as `ByteBuffer` slices of the accumulated read buffer, not
/// as `String`s: the bytes are handed straight to `JSONDecoder`, which reads them
/// without a copy, so a multi-megabyte monitor update is never transcoded to
/// `String` and back to UTF-8 on its way to the decoder.
///
/// The scan position and brace state persist across `decode` calls. `decode` is
/// re-invoked on every arriving chunk, so restarting the scan at the beginning
/// each time would re-examine the whole accumulated message — O(N·k) for a
/// message of N bytes delivered in k reads. That is quadratic for the
/// multi-megabyte `monitor` updates ovsdb-server sends for large tables
/// (Southbound `Logical_Flow` in particular). Resuming where the previous call
/// stopped keeps framing linear in the message size.
struct OVSDBJSONFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    /// Brace-nesting depth within the object currently being scanned.
    private var depth = 0
    private var inString = false
    private var escaped = false
    /// Offset from the reader index of the `{` opening the object currently
    /// being scanned; nil while between objects.
    private var objectStartOffset: Int?
    /// How many bytes from the reader index have already been examined.
    private var scannedOffset = 0

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView

        // Clamped defensively: the scan cursor is only ever advanced over bytes
        // that remain buffered, so it cannot exceed the readable range, but a
        // stale cursor would trap rather than merely re-scan.
        let resumeOffset = min(scannedOffset, view.count)

        var offset = resumeOffset
        var index = view.index(view.startIndex, offsetBy: resumeOffset)
        while index < view.endIndex {
            let byte = view[index]

            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"):
                    if depth == 0 {
                        objectStartOffset = offset
                    }
                    depth += 1
                case UInt8(ascii: "}"):
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let leading = objectStartOffset {
                            // A complete top-level object spans leading...offset inclusive.
                            let length = offset - leading + 1

                            // Everything up to and including this object leaves the
                            // buffer, so the next scan starts clean at the new reader
                            // index regardless of which branch below is taken.
                            resetScanState()

                            // Discard any leading whitespace/delimiters before the object,
                            // then read the object itself and fire it downstream.
                            buffer.moveReaderIndex(forwardBy: leading)
                            guard let frame = buffer.readSlice(length: length) else {
                                return .needMoreData
                            }
                            context.fireChannelRead(wrapInboundOut(frame))

                            // Keep any trailing bytes buffered for the next object.
                            return .continue
                        }
                    }
                default:
                    break
                }
            }

            index = view.index(after: index)
            offset += 1
        }

        // No complete object yet — remember how far we got so the next chunk
        // resumes here instead of re-scanning from the start.
        scannedOffset = offset
        return .needMoreData
    }

    private mutating func resetScanState() {
        depth = 0
        inString = false
        escaped = false
        objectStartOffset = nil
        scannedOffset = 0
    }
}
