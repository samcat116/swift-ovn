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
   - `OVSDBSocketConnection.swift`: SwiftNIO-based transport over Unix socket, TCP, or TLS (`OVSDBEndpoint` selects the transport; `UnixSocketConnection` remains as a typealias). The TLS paths are behind `#if TLS` — see Package Traits below.
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
- Real-time monitoring with `monitor_cond` method

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

Three files genuinely need full Foundation and keep a plain `import Foundation`:
- `Core/OVSDBSocketConnection.swift` — `FileManager`, `JSONSerialization`, `NSNull`, `NSLock`
- `Core/OVSDBRowEncoder.swift` — `NSError`
- `Core/OVSDBRowDecoder.swift` — `NSNull`, in `plainObject(from:)`

Tests keep `import Foundation`; XCTest links Foundation regardless, so there is
nothing to gain there.

Measured on Linux (Swift 6.2, release), the subset import buys nothing *yet*:
object code and the linked `BasicUsage` binary are both within 0.01% of the
all-Foundation build, and recompile time is inside run-to-run noise. That is
expected — as long as those three files import Foundation, the module links the
whole framework, and on Linux Foundation re-exports FoundationEssentials
anyway. The payoff only arrives if the last three imports go, so re-measure
before assuming this saves anything.

### Testing Approach
- Uses XCTest framework
- Tests located in `/Tests/SwiftOVNTests/`
- Currently imports `@testable import OVNManager` (note: may need updating to `@testable import SwiftOVN`)

### Platform Support
- Minimum Swift version: 5.9
- Supported platforms: macOS 13+, iOS 16+, watchOS 9+, tvOS 16+, visionOS 1+
- Primary deployment target: Linux servers running OVN/OVS

## License Note
The README mentions MIT license, but LICENSE.txt contains Apache 2.0. This discrepancy should be resolved.