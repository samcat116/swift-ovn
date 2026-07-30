# SwiftOVN

A comprehensive Swift package for managing OVN (Open Virtual Network) and OVS (Open vSwitch) through their JSON-RPC APIs over Unix domain sockets, TCP, or TLS.

## Features

- 🚀 **Type-Safe Swift Models**: Strongly typed, Codable structs for all OVN and OVS database schemas
- ⚡ **High Performance**: SwiftNIO-based asynchronous socket communication
- 🔌 **Flexible Transport**: Local Unix sockets or remote databases over `tcp:`/`ssl:` (NIOSSL, behind an opt-out [`TLS` trait](#the-tls-trait))
- 🔄 **Modern Concurrency**: Built with Swift's async/await and AsyncSequence
- 📡 **Real-time Monitoring**: Monitor database changes in real-time using AsyncSequence
- 🐧 **Linux-Targeted**: Built for the Linux hosts OVN/OVS run on; builds on macOS for local development
- 🛡️ **Typed Errors**: The manager APIs are `throws(OVNManagerError)`, so failures are exhaustively handleable
- 📚 **Feature Complete**: Support for all major OVN and OVS operations

## Installation

Add SwiftOVN to your Swift package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/samcat116/SwiftOVN.git", from: "1.0.0")
]
```

### The `TLS` trait

TLS support is a [package trait](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)
named `TLS`, **enabled by default** — the dependency above gets `ssl:` support
and needs no changes.

If you only ever talk to a local `unix:` socket (the common case for an agent on
an OVN host) or a cleartext `tcp:` one, opt out with `traits: []`:

```swift
dependencies: [
    .package(url: "https://github.com/samcat116/SwiftOVN.git", from: "1.0.0", traits: [])
]
```

That drops the swift-nio-ssl dependency, so your build never compiles
BoringSSL — a large C target that otherwise dominates this package's cold build
time (roughly halved on our measurements). In exchange, `OVSDBEndpoint.ssl` is
unavailable (referring to it is a compile error naming the trait) and
`OVSDBEndpoint(parsing:)` rejects `ssl:` strings at runtime.

## Quick Start

### OVN Management

```swift
import SwiftOVN

// Connect to OVN Northbound database
let SwiftOVN = SwiftOVN(socketPath: "/var/run/ovn/ovnnb_db.sock")
try await SwiftOVN.connect()

// Create a logical switch
let switch = OVNLogicalSwitch(
    name: "my-switch",
    external_ids: ["description": "My test switch"]
)
let switchUUID = try await SwiftOVN.createLogicalSwitch(switch)

// Create a logical switch port
let port = OVNLogicalSwitchPort(
    name: "vm1-port",
    addresses: ["02:ac:10:ff:01:30 10.0.0.10"],
    port_security: ["02:ac:10:ff:01:30 10.0.0.10"]
)
let portUUID = try await SwiftOVN.createLogicalSwitchPort(port)

// Get all logical switches
let switches = try await SwiftOVN.getLogicalSwitches()
print("Found \(switches.count) logical switches")
```

### OVS Management

```swift
import SwiftOVN

// Connect to OVS database
let ovsManager = OVSManager(socketPath: "/var/run/openvswitch/db.sock")
try await ovsManager.connect()

// Create a bridge
let bridge = OVSBridge(
    name: "br-int",
    fail_mode: "secure",
    protocols: ["OpenFlow13"]
)
let bridgeUUID = try await ovsManager.createBridge(bridge)

// Create a port
let port = OVSPort(
    name: "veth1",
    interfaces: ["interface-uuid-here"]
)
let portUUID = try await ovsManager.createPort(port)

// Get bridge statistics
let stats = try await ovsManager.getBridgeStatistics(bridge: "br-int")
print("Bridge statistics: \(stats)")
```

### Real-time Monitoring

```swift
// Start monitoring OVN database changes
let monitorId = try await SwiftOVN.startMonitoring(tables: ["Logical_Switch", "Logical_Switch_Port"])

// Process updates in real-time
do {
    for try await update in SwiftOVN.monitorUpdates() {
        if let newRow = update.new {
            print("Row updated: \(newRow)")
        }
        if let oldRow = update.old {
            print("Previous row: \(oldRow)")
        }
    }
} catch OVNManagerError.notificationsDropped(let count) {
    // The consumer fell behind and `count` updates were discarded, so this
    // view is now incomplete. Restart the monitor for a fresh snapshot.
    print("Missed \(count) updates, resynchronizing")
}

// Stop monitoring when done
try await SwiftOVN.stopMonitoring(monitorId: monitorId)
```

Update streams buffer a bounded number of updates per consumer
(`OVSDBSocketConnection.notificationBufferSize`). A consumer that stops
draining — easy to do on a Southbound `Logical_Flow` monitor, where updates are
large and frequent — gets `OVNManagerError.notificationsDropped` instead of
growing the buffer until the process runs out of memory. Work that can lag
behind the stream should hand updates to its own queue, and re-monitor when a
drop is reported.

## Architecture

### Core Components

- **JSONRPCClient**: Low-level JSON-RPC communication over any OVSDB transport
- **OVSDBSocketConnection**: SwiftNIO-based Unix socket, TCP, and TLS transport (`UnixSocketConnection` remains as an alias)
- **OVSDBEndpoint**: Endpoint description (`.unix`/`.tcp`/`.ssl`) with OVN-style string parsing
- **OVSDBConnection**: OVSDB protocol implementation with monitoring support
- **SwiftOVN**: High-level interface for OVN operations
- **OVSManager**: High-level interface for OVS operations

### Models

The package includes comprehensive Swift models for:

#### OVN Models
- `OVNLogicalSwitch` - Virtual switches in the logical network
- `OVNLogicalSwitchPort` - Ports on logical switches
- `OVNLogicalRouter` - Virtual routers
- `OVNLogicalRouterPort` - Ports on logical routers
- `OVNACL` - Access control lists
- `OVNPortGroup` - Port groups for scalable security-group ACLs
- `OVNAddressSet` - Named address sets referenced from ACL match strings as `$name`
- `OVNLoadBalancer` - Load balancing rules
- `OVNNAT` - Network address translation rules
- `OVNQoS` - Logical switch rate limiting and DSCP marking
- `OVNMeter` / `OVNMeterBand` - Named rate limiters, e.g. for ACL log rate limiting (`OVNACL.meter`)
- `OVNDHCPOptions` - DHCP configuration

#### OVS Models
- `OVSBridge` - Open vSwitch bridges
- `OVSPort` - Bridge ports
- `OVSInterface` - Network interfaces
- `OVSController` - OpenFlow controllers
- `OVSFlow` - Flow table entries
- `OVSMirror` - Port mirroring configuration
- `OVSQoS` - Quality of service policies (the Open_vSwitch `QoS` table, distinct from `OVNQoS`)

## Advanced Usage

### Remote Databases (TCP/SSL)

A central OVN deployment usually exposes its northbound database on port 6641
and southbound on 6642. Connect to a remote database with an `OVSDBEndpoint`:

```swift
// Cleartext TCP
let manager = OVNManager(endpoint: .tcp(host: "ovn-central.example.com", port: 6641))
try await manager.connect()

// TLS with an ovn-pki-style private CA and client certificate
let tls = OVSDBTLSConfiguration(
    caCertificatePath: "/etc/ovn/cacert.pem",
    clientCertificatePath: "/etc/ovn/client-cert.pem",
    clientPrivateKeyPath: "/etc/ovn/client-privkey.pem"
)
let secureManager = OVNManager(
    endpoint: .ssl(host: "ovn-central.example.com", port: 6641, tls: tls),
    database: OVNDatabase.northbound
)

// OVN-style connection strings are also supported
let endpoint = try OVSDBEndpoint(parsing: "tcp:ovn-central.example.com:6641")
```

The existing `socketPath:` initializers are unchanged and equivalent to
`.unix(path:)`.

The `.ssl` endpoint requires the [`TLS` trait](#the-tls-trait), which is enabled
by default. `.unix` and `.tcp` work either way.

### Custom Connection Configuration

```swift
// Custom event loop group
let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

// Custom logger
var logger = Logger(label: "my-ovn-app")
logger.logLevel = .debug

let SwiftOVN = SwiftOVN(
    socketPath: "/custom/path/to/ovnnb_db.sock",
    database: OVNDatabase.northbound,
    eventLoopGroup: eventLoopGroup,
    logger: logger
)
```

### Building Complex Queries

```swift
// Find logical switches with specific external IDs
let switches = try await SwiftOVN.getLogicalSwitches()
let productionSwitches = switches.filter {
    $0.external_ids?["environment"] == "production"
}

// Create ACL with specific conditions
let acl = OVNACL(
    priority: 1000,
    direction: "to-lport",
    match: "ip4.src == 192.168.1.0/24 && tcp.dst == 80",
    action: "allow",
    log: true,
    name: "allow-web-traffic"
)
try await SwiftOVN.createACL(acl)
```

### Flow Management with OVS

```swift
// Build OpenFlow rules using the flow builder
let flow = ovsManager.flowBuilder()
    .table(0)
    .priority(1000)
    .match("in_port=1,dl_type=0x0800")
    .actions("output:2")
    .idleTimeout(300)
    .build()

// Note: Flow operations typically require ovs-ofctl commands
// This package focuses on OVSDB operations
```

## Error Handling

Every throwing operation on `OVNManaging` and `OVSManaging` is declared
`throws(OVNManagerError)`, so the `catch` binds that type directly — no cast, no
`as?`, and a `switch` over it can be exhaustive:

```swift
do {
    try await ovnManager.connect()
    let switches = try await ovnManager.getLogicalSwitches()
} catch .connectionFailed(let message) {
    print("Connection failed: \(message)")
} catch .timeoutError {
    print("Operation timed out")
} catch .rpcError(let rpcError) {
    print("RPC Error: \(rpcError.message)")
} catch {
    // `error` is an OVNManagerError here, so this is the remaining cases —
    // not "anything at all".
    print("OVSDB error: \(error)")
}
```

Errors from the layers underneath are wrapped before they reach you rather than
leaking out: a row that fails to decode arrives as `.decodingError`, a model
that fails to encode as `.encodingError`, and NIO channel and TLS failures as
`.connectionFailed`, each carrying the original error.

The one exception is `monitorUpdates()`. Its `AsyncThrowingStream` still has a
`Failure` of `any Error` because every `AsyncThrowingStream` initializer in the
standard library is constrained that way; only `OVNManagerError` is ever thrown
into it, so match on the type in the `catch`:

```swift
} catch OVNManagerError.notificationsDropped(let count) {
```

## Database Support

### OVN Databases
- **Northbound**: High-level logical network configuration
- **Southbound**: Low-level physical network state

### OVS Database
- **Open_vSwitch**: Configuration and state of Open vSwitch instances

## Requirements

- Swift 6.2+
- SwiftNIO 2.98.0+, and swift-nio-ssl 2.37.1+ when the [`TLS` trait](#the-tls-trait)
  is enabled (the default)
- **Linux** for deployment — OVN/OVS run there, and that is where this library
  is meant to run. macOS 26+ builds for local development and testing only;
  there is no OVSDB server to connect to on Apple platforms, so the floor is
  set to the newest release rather than the oldest one that would work.
- Access to an OVSDB server over a Unix domain socket, `tcp:`, or `ssl:`

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

This package is released under the MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [Open Virtual Network (OVN)](https://www.ovn.org/)
- [Open vSwitch](https://www.openvswitch.org/)
- [SwiftNIO](https://github.com/apple/swift-nio)
- [RFC 7047 - OVSDB Management Protocol](https://tools.ietf.org/html/rfc7047)
