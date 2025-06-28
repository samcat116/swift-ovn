import Foundation
import SwiftOVN
import Logging

@main
struct BasicUsageExample {
    static func main() async throws {
        // Configure logging
        var logger = Logger(label: "ovn-example")
        logger.logLevel = .info

        print("🚀 OVNManager Basic Usage Example")
        print("==================================")

        // Example 1: OVN Northbound Operations
        await runOVNExample(logger: logger)

        // Example 2: OVS Operations
        await runOVSExample(logger: logger)

        // Example 3: Monitoring
        await runMonitoringExample(logger: logger)
    }

    static func runOVNExample(logger: Logger) async {
        print("\n📡 OVN Northbound Database Example")
        print("-----------------------------------")

        do {
            // Connect to OVN Northbound database
            let ovnManager = OVNManager(
                socketPath: "/var/run/ovn/ovnnb_db.sock",
                database: OVNDatabase.northbound,
                logger: logger
            )

            print("Connecting to OVN Northbound database...")
            try await ovnManager.connect()
            print("✅ Connected successfully!")

            // List available databases
            let databases = try await ovnManager.listDatabases()
            print("📋 Available databases: \(databases)")

            // Create a logical switch
            print("\nCreating logical switch...")
            let logicalSwitch = OVNLogicalSwitch(
                name: "example-switch",
                external_ids: [
                    "description": "Example logical switch",
                    "environment": "demo"
                ]
            )

            let switchUUID = try await ovnManager.createLogicalSwitch(logicalSwitch)
            print("✅ Created logical switch with UUID: \(switchUUID)")

            // Create logical switch ports
            print("\nCreating logical switch ports...")

            let port1 = OVNLogicalSwitchPort(
                name: "vm1-port",
                addresses: ["02:ac:10:ff:01:30 10.0.0.10"],
                port_security: ["02:ac:10:ff:01:30 10.0.0.10"],
                external_ids: ["vm": "vm1", "tenant": "demo"]
            )

            let port2 = OVNLogicalSwitchPort(
                name: "vm2-port",
                addresses: ["02:ac:10:ff:01:31 10.0.0.11"],
                port_security: ["02:ac:10:ff:01:31 10.0.0.11"],
                external_ids: ["vm": "vm2", "tenant": "demo"]
            )

            let port1UUID = try await ovnManager.createLogicalSwitchPort(port1)
            let port2UUID = try await ovnManager.createLogicalSwitchPort(port2)

            print("✅ Created ports: \(port1UUID), \(port2UUID)")

            // Create ACL to allow traffic between VMs
            print("\nCreating ACL...")
            let acl = OVNACL(
                priority: 1000,
                direction: "to-lport",
                match: "ip4.src == 10.0.0.0/24",
                action: "allow",
                log: false,
                name: "allow-internal-traffic",
                external_ids: ["policy": "internal-communication"]
            )

            let aclUUID = try await ovnManager.createACL(acl)
            print("✅ Created ACL with UUID: \(aclUUID)")

            // List all logical switches
            print("\nListing all logical switches...")
            let lswitches = try await ovnManager.getLogicalSwitches()
            for lswitch in lswitches {
                print(lswitch.name)
                if let externalIds = lswitch.external_ids {
                    print("    External IDs: \(externalIds)")
                }
            }

            // Create a logical router
            print("\nCreating logical router...")
            let router = OVNLogicalRouter(
                name: "example-router",
                external_ids: [
                    "description": "Example logical router",
                    "type": "gateway"
                ]
            )

            let routerUUID = try await ovnManager.createLogicalRouter(router)
            print("✅ Created logical router with UUID: \(routerUUID)")

            // Create router port
            print("\nCreating router port...")
            let routerPort = OVNLogicalRouterPort(
                name: "router-to-switch",
                mac: "02:ac:10:ff:00:01",
                networks: ["10.0.0.1/24"],
                external_ids: ["role": "gateway"]
            )

            let routerPortUUID = try await ovnManager.createLogicalRouterPort(routerPort)
            print("✅ Created router port with UUID: \(routerPortUUID)")

            // Clean up (optional - comment out to keep resources)
            print("\nCleaning up resources...")
            try await ovnManager.deleteACL(uuid: aclUUID)
            try await ovnManager.deleteLogicalSwitchPort(uuid: port1UUID)
            try await ovnManager.deleteLogicalSwitchPort(uuid: port2UUID)
            try await ovnManager.deleteLogicalRouterPort(uuid: routerPortUUID)
            try await ovnManager.deleteLogicalRouter(uuid: routerUUID)
            try await ovnManager.deleteLogicalSwitch(uuid: switchUUID)
            print("✅ Cleanup completed")

            try await ovnManager.disconnect()
            print("✅ Disconnected from OVN")

        } catch {
            print("❌ OVN Example failed: \(error)")
        }
    }

    static func runOVSExample(logger: Logger) async {
        print("\n🌉 OVS Database Example")
        print("------------------------")

        do {
            // Connect to OVS database
            let ovsManager = OVSManager(
                socketPath: "/var/run/openvswitch/db.sock",
                logger: logger
            )

            print("Connecting to OVS database...")
            try await ovsManager.connect()
            print("✅ Connected successfully!")

            // List available databases
            let databases = try await ovsManager.listDatabases()
            print("📋 Available databases: \(databases)")

            // Create a bridge
            print("\nCreating OVS bridge...")
            let bridge = OVSBridge(
                name: "br-example",
                protocols: ["OpenFlow13"],
                fail_mode: "secure",
                external_ids: [
                    "description": "Example OVS bridge",
                    "environment": "demo"
                ]
            )

            let bridgeUUID = try await ovsManager.createBridge(bridge)
            print("✅ Created bridge with UUID: \(bridgeUUID)")

            // Create an interface
            print("\nCreating interface...")
            let interface = OVSInterface(
                name: "example-if",
                interfaceType: "internal",
                external_ids: ["purpose": "example"]
            )

            let interfaceUUID = try await ovsManager.createInterface(interface)
            print("✅ Created interface with UUID: \(interfaceUUID)")

            // Create a port
            print("\nCreating port...")
            let port = OVSPort(
                name: "example-port",
                interfaces: [interfaceUUID],
                external_ids: ["bridge": "br-example"]
            )

            let portUUID = try await ovsManager.createPort(port)
            print("✅ Created port with UUID: \(portUUID)")

            // List all bridges
            print("\nListing all bridges...")
            let bridges = try await ovsManager.getBridges()
            for bridge in bridges {
                print("  - \(bridge.name) (UUID: \(bridge.uuid ?? "unknown"))")
                if let protocols = bridge.protocols {
                    print("    Protocols: \(protocols)")
                }
                if let failMode = bridge.fail_mode {
                    print("    Fail mode: \(failMode)")
                }
            }

            // Create a mirror
            print("\nCreating mirror...")
            let mirror = OVSMirror(
                name: "example-mirror",
                select_all: true,
                output_port: portUUID,
                external_ids: ["purpose": "monitoring"]
            )

            let mirrorUUID = try await ovsManager.createMirror(mirror)
            print("✅ Created mirror with UUID: \(mirrorUUID)")

            // Get bridge statistics (if available)
            print("\nGetting bridge statistics...")
            let stats = try await ovsManager.getBridgeStatistics(bridge: "br-example")
            if !stats.isEmpty {
                print("📊 Bridge statistics: \(stats)")
            } else {
                print("📊 No statistics available")
            }

            // Clean up (optional)
            print("\nCleaning up resources...")
            try await ovsManager.deleteMirror(uuid: mirrorUUID)
            try await ovsManager.deletePort(uuid: portUUID)
            try await ovsManager.deleteInterface(uuid: interfaceUUID)
            try await ovsManager.deleteBridge(uuid: bridgeUUID)
            print("✅ Cleanup completed")

            try await ovsManager.disconnect()
            print("✅ Disconnected from OVS")

        } catch {
            print("❌ OVS Example failed: \(error)")
        }
    }

    static func runMonitoringExample(logger: Logger) async {
        print("\n👁️ Database Monitoring Example")
        print("--------------------------------")

        do {
            let ovnManager = OVNManager(
                socketPath: "/var/run/ovn/ovnnb_db.sock",
                logger: logger
            )

            print("Connecting for monitoring...")
            try await ovnManager.connect()

            // Start monitoring specific tables
            print("Starting monitor for Logical_Switch and Logical_Switch_Port tables...")
            let monitorId = try await ovnManager.startMonitoring(
                tables: ["Logical_Switch", "Logical_Switch_Port"]
            )
            print("✅ Monitor started with ID: \(monitorId)")

            // Create a timeout task to limit monitoring duration
            let monitoringTask = Task {
                var updateCount = 0
                for try await update in ovnManager.monitorUpdates() {
                    updateCount += 1
                    print("📡 Update #\(updateCount) received:")

                    if let newRow = update.new {
                        print("  New/Updated row: \(newRow)")
                    }

                    if let oldRow = update.old {
                        print("  Previous row: \(oldRow)")
                    }

                    // Stop after 5 updates or 30 seconds
                    if updateCount >= 5 {
                        break
                    }
                }
            }

            // Run monitoring for a limited time
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                monitoringTask.cancel()
            }

            print("Monitoring for changes (will stop after 5 updates or 30 seconds)...")
            print("You can create/modify/delete logical switches in another terminal to see updates")

            // Wait for either task to complete
            _ = await Task.race(monitoringTask, timeoutTask)

            // Stop monitoring
            try await ovnManager.stopMonitoring(monitorId: monitorId)
            print("✅ Monitoring stopped")

            try await ovnManager.disconnect()
            print("✅ Disconnected")

        } catch {
            print("❌ Monitoring example failed: \(error)")
        }
    }
}

// Helper extension for Task racing
extension Task where Success == Void, Failure == Error {
    static func race<T>(_ task1: Task<T, Error>, _ task2: Task<T, Error>) async -> T? {
        return await withTaskGroup(of: T?.self) { group in
            group.addTask {
                do {
                    return try await task1.value
                } catch {
                    return nil
                }
            }
            group.addTask {
                do {
                    return try await task2.value
                } catch {
                    return nil
                }
            }

            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }
}
