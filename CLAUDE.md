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
   - `UnixSocketConnection.swift`: SwiftNIO-based Unix socket implementation
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