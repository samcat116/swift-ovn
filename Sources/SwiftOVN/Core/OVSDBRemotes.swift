/// The remotes a connection may attach to, in preference order.
///
/// A clustered (RAFT) `ovsdb-server` — the normal production deployment for OVN
/// — runs three or more servers, any of which can stop serving at any moment:
/// a leader election drops the connections to the old leader, and writes are
/// only accepted by the leader. A connection that knows one address therefore
/// cannot survive a normal cluster event, which is why OVN's own tooling takes a
/// list (`ovn-nbctl --db=tcp:a:6641,tcp:b:6641,tcp:c:6641`).
///
/// The list is non-empty by construction and de-duplicated with the first
/// occurrence of each remote kept, so a repeated address cannot waste a
/// connection attempt.
public struct OVSDBRemotes: Sendable, Equatable {
    /// The remotes, in the order they are tried. Never empty.
    public let endpoints: [OVSDBEndpoint]

    /// One or more remotes. The first is required, so this cannot produce an
    /// empty list and does not throw.
    public init(_ first: OVSDBEndpoint, _ others: OVSDBEndpoint...) {
        self.endpoints = Self.deduplicated([first] + others)
    }

    /// Remotes from a collection, rejecting an empty one — a connection with
    /// nowhere to connect to is a programming error worth reporting at
    /// construction rather than at connect time.
    public init(_ endpoints: [OVSDBEndpoint]) throws(OVNManagerError) {
        guard !endpoints.isEmpty else {
            throw OVNManagerError.connectionFailed("An OVSDB connection needs at least one remote")
        }
        self.endpoints = Self.deduplicated(endpoints)
    }

    /// Parses a comma-separated list of OVN/OVS-style connection strings, the
    /// form `ovn-nbctl --db` and `ovsdb-client` accept:
    ///
    /// ```
    /// tcp:10.0.0.1:6641,tcp:10.0.0.2:6641,tcp:10.0.0.3:6641
    /// ```
    ///
    /// Surrounding whitespace around each element is ignored. See
    /// `OVSDBEndpoint(parsing:)` for the individual forms.
    public init(parsing string: String) throws(OVNManagerError) {
        // A loop rather than `map`: `Sequence.map` is `rethrows`, which erases a
        // typed throw back to `any Error`.
        var parsed: [OVSDBEndpoint] = []
        for element in string.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = Self.trimmingWhitespace(element)
            guard !trimmed.isEmpty else {
                throw OVNManagerError.connectionFailed("Invalid OVSDB remote list '\(string)': empty element")
            }
            parsed.append(try OVSDBEndpoint(parsing: trimmed))
        }
        try self.init(parsed)
    }

    /// The remote tried first.
    public var first: OVSDBEndpoint {
        return endpoints[0]
    }

    public var count: Int {
        return endpoints.count
    }

    /// The remote at `index`, which the reconnect logic rotates through.
    public subscript(index: Int) -> OVSDBEndpoint {
        return endpoints[index]
    }

    /// Trims leading and trailing whitespace without reaching for
    /// `trimmingCharacters(in:)`, which would pull Foundation into a file that
    /// otherwise needs nothing from it.
    private static func trimmingWhitespace(_ substring: Substring) -> String {
        var slice = substring
        while let first = slice.first, first.isWhitespace {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last.isWhitespace {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    /// Keeps the first occurrence of each remote and drops later repeats.
    /// `OVSDBEndpoint` is `Equatable` but not `Hashable` (its TLS payload is
    /// not), so this is a linear scan rather than a `Set`; the lists are three
    /// or four elements long.
    private static func deduplicated(_ endpoints: [OVSDBEndpoint]) -> [OVSDBEndpoint] {
        var unique: [OVSDBEndpoint] = []
        unique.reserveCapacity(endpoints.count)
        for endpoint in endpoints where !unique.contains(endpoint) {
            unique.append(endpoint)
        }
        return unique
    }
}

extension OVSDBRemotes: CustomStringConvertible {
    /// The comma-separated form, which parses back to the same list.
    public var description: String {
        return endpoints.map(\.description).joined(separator: ",")
    }
}
