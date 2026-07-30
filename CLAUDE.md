# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftOVN is a Swift package providing type-safe interfaces for managing OVN (Open Virtual Network) and OVS (Open vSwitch) through their JSON-RPC APIs over Unix domain sockets. The library uses SwiftNIO for high-performance asynchronous networking and modern Swift concurrency features.

## Common Commands

### Build and Test
```bash
# Build the package
swift build

# Run tests
swift test

# Build/test with the TLS trait off (the other configuration CI covers).
# Both must pass — see Package Traits below.
swift build --disable-default-traits
swift test --disable-default-traits

# Build in release mode
swift build -c release

# Run the example application
swift run BasicUsage

# Clean build artifacts
swift package clean
```

### Development Commands
```bash
# Update dependencies
swift package update

# Resolve dependencies
swift package resolve

# Generate Xcode project (if needed)
swift package generate-xcodeproj

# Show dependency graph
swift package show-dependencies
```

## Architecture and Key Components

### Core Architecture Pattern
The codebase follows a clean architecture with clear separation of concerns:

1. **Low-level networking** (`/Sources/SwiftOVN/Core/`):
   - `JSONRPCClient.swift`: Handles JSON-RPC protocol communication
   - `OVSDBSocketConnection.swift`: Public transport facade and channel bootstrap over Unix socket, TCP, or TLS (`OVSDBEndpoint` selects the transport; `UnixSocketConnection` remains as a typealias). The TLS paths are behind `#if TLS` — see Package Traits below.
   - `OVSDBConnectionCore.swift`: The `NIOAsyncChannel` state machine — session, in-flight requests, inbound routing. Every piece of mutable transport state lives here, as actor state or behind a `Mutex`; there is no `@unchecked Sendable` in the transport
   - `OVSDBJSONFrameDecoder.swift`: Brace-depth framer, emits one `ByteBuffer` per top-level JSON object
   - `JSONRPCFrameEnvelope.swift`: Scans a frame's `method`/`id` for routing without parsing the payload
   - `JSONRPCNotificationHub.swift`: Bounded fan-out of server notifications, with drop reporting
   - `OVSDBConnection.swift`: OVSDB protocol with real-time monitoring via AsyncSequence

2. **High-level managers** (`/Sources/SwiftOVN/Managers/`):
   - `OVNManager.swift`: Main API for OVN operations (northbound/southbound databases)
   - `OVSManager.swift`: Main API for OVS operations

3. **Protocol-oriented design** (`/Sources/SwiftOVN/Protocols/`):
   - `OVNManaging` and `OVSManaging` protocols define the public API contracts

4. **Comprehensive model layer** (`/Sources/SwiftOVN/Models/`):
   - One model per file approach
   - Strongly-typed Codable structs for all OVN/OVS entities
   - Models are grouped by category (OVN, OVS, JSONRPC, OVSDB)

### Key Technical Patterns

1. **Async/Await Throughout**: All operations use modern Swift concurrency
2. **AsyncSequence for Monitoring**: Real-time database changes stream via AsyncSequence
3. **SwiftNIO Event Loop**: Customizable event loop groups for performance tuning
4. **Structured Logging**: Uses swift-log for configurable logging levels

### Error Handling Pattern
The codebase uses a comprehensive `SwiftOVNError` enum with specific cases:
- `connectionFailed(String)`
- `timeoutError`
- `rpcError(JSONRPCError)`
- `invalidResponse`
- `encodingError`
- `decodingError`

## Important Implementation Details

### Package Traits

The package declares one trait, `TLS`, in the default trait set. It gates the
`swift-nio-ssl` (and `NIOTLS`) dependency so consumers that only use `unix:` or
`tcp:` endpoints do not compile BoringSSL.

When touching TLS code, keep both configurations building:

- Guard TLS-only code with `#if TLS`. That includes the `NIOSSL`/`NIOTLS`
  imports, `TLSSetup`/`makeTLSSetup()`/`makeSSLContext`/`isIPAddressLiteral`,
  and `TLSHandshakeWaitHandler` in `OVSDBSocketConnection.swift`.
- Any `switch` over `OVSDBEndpoint` needs its `case .ssl` inside `#if TLS`,
  because with the trait off that case is `@available(*, unavailable)` and is
  excluded from exhaustiveness checking.
- `OVSDBEndpoint.ssl` (both the case and the `ssl(host:port:)` convenience) is
  declared twice — once normally, once as `@available(*, unavailable, message:)`
  — so a trait-off build reports *why* it is missing rather than "type has no
  member 'ssl'". Keep the two messages in sync.
- `OVSDBTLSConfiguration` stays available in both configurations; it is inert
  data, and the unavailable `ssl` case still has to name its payload type.
- `OVSDBEndpoint(parsing:)` cannot fail at compile time for an `ssl:` string, so
  with the trait off it throws instead.
- New TLS-only tests go behind `#if TLS`; `TLSTransportTests.swift` wraps the
  whole file.

Note that a `--disable-default-traits` build rewrites `Package.resolved` to drop
the now-unused `swift-nio-ssl` pin. That is SwiftPM pruning, not a real change —
`git checkout Package.resolved` after building that way, and keep the pin in the
committed lockfile so the default configuration resolves offline.

### Socket Paths
Default Unix socket paths used in examples:
- OVN Northbound: `/var/run/ovn/ovnnb_db.sock`
- OVN Southbound: `/var/run/ovn/ovnsb_db.sock`
- OVS: `/var/run/openvswitch/db.sock`

### Database Operations
All database operations follow the OVSDB protocol (RFC 7047) with:
- Transactional operations using `OVSDBOperation`
- Conditional operations with `OVSDBCondition`
- Mutations with `OVSDBMutation`
- Real-time monitoring with `monitor` (RFC 7047) or, via
  `startConditionalMonitoring`, ovsdb-server's `monitor_cond` /
  `monitor_cond_since` / `monitor_cond_change`

### Monitor Methods
`OVSDBConnection` negotiates monitor methods per connection, most to least
capable: `monitor_cond_since`, `monitor_cond`, `monitor` (see
`OVSDBMonitorMethod.fallback`). Two things that look like oversights but are not:

- A `monitor_cond`/`monitor_cond_since` `modify` is reported as
  `OVSDBUpdate.diff` — the changed columns — with `old`/`new` left nil, rather
  than being turned into a row. Synthesizing the pair needs both a full row cache
  *and* the schema: a modify expresses set/map columns as a difference, and
  ovsdb-server serializes a single-element set as a bare atom, so set-vs-scalar
  cannot be told apart without column types. Deciding a cache belongs here would
  also mean one designated consumer applying each diff exactly once, since
  applying an XOR-style diff twice corrupts the row — the current fan-out has no
  such consumer.
- A monitor request carrying `whereConditions` is *refused* rather than
  downgraded when the server implements neither conditional method. Silently
  dropping the filter would deliver every row as if it matched. `where` is also
  stripped from a plain `monitor` request rather than left empty: ovsdb-server
  parses `<monitor-request>` strictly and fails the whole request over an
  unexpected member.

`JSONRPCError` decodes ovsdb-server's JSON-RPC 1.0 error shapes (a bare string,
or `{"error":…, "details":…}`) as well as JSON-RPC 2.0's `{code, message}`.
Before that, every real error reply failed to decode and surfaced as an opaque
`decodingError` — and `isUnknownMethod`, which the fallback depends on, was
unreachable.

### Foundation Imports
Linux is the primary deployment target, and there full `Foundation` is far more
than this package needs. Source files therefore import the essentials subset
where they can:

```swift
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
```

`canImport(FoundationEssentials)` is true on Linux and false on Apple platforms,
where the `#else` branch keeps things building. New files should follow the same
pattern — or import nothing at all, since most models only need stdlib
`Codable`.

No source file imports full Foundation any more. `OVSDBJSONFrameDecoder.swift`
and `JSONRPCFrameEnvelope.swift` import neither — they work on `ByteBuffer` and
need nothing from Foundation at all, which is the better end state where it is
reachable. Keeping it that way means preferring:

- `access(path, F_OK)` over `FileManager.fileExists` (see
  `OVSDBChannelBootstrap.connect`)
- `Mutex` / actor state over `NSLock`
- a `Decodable` envelope over `JSONSerialization` plus `as?` casts
- a plain `Error` type over `NSError` with `NSLocalizedDescriptionKey` (see
  `OVSDBRowEncodingError`)

Tests keep `import Foundation`; XCTest links Foundation regardless, so there is
nothing to gain there.

**Foundation is still linked, via `NIOFoundationCompat`.** That dependency is
what lets `OVSDBConnectionCore` code JSON straight into a `ByteBuffer` instead
of round-tripping through `Data`, and it imports Foundation itself, so the
subset imports above buy no binary-size win on their own. Measured on Linux
(Swift 6.2, release) against the same tree with plain `import Foundation`:
object code and the `BasicUsage` binary both land within 0.01%, `ldd` shows the
same four Foundation libraries either way, and recompile time is inside
run-to-run noise.

The size argument only cashes out if `NIOFoundationCompat` goes too. Measured on
this branch before the #51 merge, with no Foundation anywhere in the graph, a
`--static-swift-stdlib` `BasicUsage` linked at 55.8 MB against 104.1 MB — a 46%
cut, though only ~70 KB of it with the dynamic stdlib. That trade — one `Data`
copy per frame against half the static binary — was considered and **not**
taken: SwiftOVN is a library, its consumers choose the linking mode, and the
zero-copy frame path is deliberate. Re-measure before revisiting either side.

### Testing Approach
- Uses Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`/`#require`).
  There is no XCTest left in the target — do not add any back.
- Tests located in `/Tests/SwiftOVNTests/`, importing `@testable import SwiftOVN`
- Suites run in parallel by default, so nothing may share mutable global state.
  A suite needing per-test setup/teardown is a `final class` with `init`/`deinit`
  (`MessageRoutingTests`, `TCPTransportTests`, `TLSTransportTests`, which own an
  event loop group); everything else is a `struct`.
- **Never block in `deinit`.** Those three suites tear their group down with
  `group.shutdownGracefully { _ in }`, not `syncShutdownGracefully()`. Swift
  Testing runs tests as tasks, so `deinit` lands on a cooperative thread, and
  blocking one of the pool's few threads while other suites' read-loop tasks
  wait for a thread deadlocks the entire run — it hangs with no failure output.
  This is the one thing that does not survive a mechanical `tearDown` → `deinit`
  translation.
- `OVNManagerError` is not `Equatable`, so `#expect(throws:)` cannot name a
  specific case. Compare `errorCase` (see `TestSupport.swift`) instead:
  `#expect(error?.errorCase == .timeoutError)`.
- Prefer `@Test(arguments:)` over a loop or near-duplicate test bodies. The
  framing cases in `OVNManagerTests.swift` show the pattern: a `FramingCase`
  value conforming to `CustomTestStringConvertible` so each case gets a
  readable label, with the per-case rationale as a comment on the case.

### Platform Support
- Minimum Swift version: 5.9
- Supported platforms: macOS 13+, iOS 16+, watchOS 9+, tvOS 16+, visionOS 1+
- Primary deployment target: Linux servers running OVN/OVS

## License Note
The README mentions MIT license, but LICENSE.txt contains Apache 2.0. This discrepancy should be resolved.