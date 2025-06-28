import Foundation
import NIO
import NIOPosix
import Logging

public final class UnixSocketConnection {
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger
    private var channel: Channel?
    private let socketPath: String
    private var isConnected: Bool = false
    private var responseRouter: JSONRPCResponseRouter?
    
    public init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.socketPath = socketPath
        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.logger = logger ?? Logger(label: "ovn-manager.unix-socket")
    }
    
    
    public func connect() -> EventLoopFuture<Void> {
        guard !isConnected else {
            logger.debug("Already connected to Unix socket")
            return eventLoopGroup.next().makeSucceededFuture(())
        }
        
        logger.info("Connecting to Unix socket at: \(socketPath)")
        logger.debug("Checking if socket file exists...")
        
        // Check if socket file exists
        if !FileManager.default.fileExists(atPath: socketPath) {
            logger.error("Socket file does not exist at path: \(socketPath)")
            return eventLoopGroup.next().makeFailedFuture(OVNManagerError.connectionFailed("Socket file not found: \(socketPath)"))
        }
        
        logger.debug("Socket file exists, creating bootstrap...")
        
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                self.logger.debug("Initializing channel pipeline...")
                let router = JSONRPCResponseRouter(logger: self.logger, eventLoopGroup: self.eventLoopGroup)
                self.responseRouter = router
                return channel.pipeline.addHandlers([
                    ByteToMessageHandler(LineDelimitedFrameDecoder()),
                    MessageToByteHandler(StringToByteEncoder()),
                    router
                ]).map { _ in
                    self.logger.debug("Channel pipeline initialized successfully")
                }.flatMapError { error in
                    self.logger.error("Failed to initialize channel pipeline: \(error)")
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        
        logger.debug("Attempting to connect to Unix domain socket...")
        
        return bootstrap.connect(unixDomainSocketPath: socketPath)
            .map { channel in
                self.logger.debug("Raw connection established, setting up channel...")
                self.channel = channel
                self.isConnected = true
                self.logger.info("Successfully connected to Unix socket")
                self.logger.debug("Channel active: \(channel.isActive), writable: \(channel.isWritable)")
            }
            .flatMapError { error in
                self.logger.error("Failed to connect to Unix socket: \(error)")
                self.logger.error("Error type: \(type(of: error))")
                if let ioError = error as? IOError {
                    self.logger.error("IO error code: \(ioError.errnoCode)")
                }
                return self.eventLoopGroup.next().makeFailedFuture(OVNManagerError.connectionFailed("Failed to connect to \(self.socketPath): \(error)"))
            }
    }
    
    public func disconnect() -> EventLoopFuture<Void> {
        guard let channel = channel, isConnected else {
            return eventLoopGroup.next().makeSucceededFuture(())
        }
        
        logger.info("Disconnecting from Unix socket")
        self.isConnected = false
        self.responseRouter = nil
        
        return channel.close().map {
            self.channel = nil
            self.logger.info("Successfully disconnected from Unix socket")
        }
    }
    
    public func send<T: Codable>(_ message: T) -> EventLoopFuture<Void> {
        guard let channel = channel, isConnected else {
            return eventLoopGroup.next().makeFailedFuture(
                OVNManagerError.connectionFailed("Not connected to socket")
            )
        }
        
        do {
            let encoder = Foundation.JSONEncoder()
            let data = try encoder.encode(message)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw OVNManagerError.encodingError(
                    NSError(domain: "UnixSocketConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert data to string"])
                )
            }
            
            logger.debug("Sending message: \(jsonString)")
            return channel.writeAndFlush(jsonString + "\n")
        } catch {
            logger.error("Failed to encode message: \(error)")
            return eventLoopGroup.next().makeFailedFuture(OVNManagerError.encodingError(error))
        }
    }
    
    public func receive<T: Codable>(as type: T.Type, requestId: JSONRPCIdentifier, timeout: TimeAmount = .seconds(30)) -> EventLoopFuture<T> {
        guard let responseRouter = responseRouter, isConnected else {
            return eventLoopGroup.next().makeFailedFuture(
                OVNManagerError.connectionFailed("Not connected to socket")
            )
        }
        
        return responseRouter.waitForResponse(requestId: requestId, type: T.self, timeout: timeout)
    }
    
    // For monitoring - receives any message without filtering by request ID
    public func receiveAny<T: Codable>(as type: T.Type, timeout: TimeAmount = .seconds(30)) -> EventLoopFuture<T> {
        guard let responseRouter = responseRouter, isConnected else {
            return eventLoopGroup.next().makeFailedFuture(
                OVNManagerError.connectionFailed("Not connected to socket")
            )
        }
        
        return responseRouter.waitForAnyResponse(type: T.self, timeout: timeout)
    }
    
    public var isConnectionActive: Bool {
        return isConnected && channel?.isActive == true
    }
}

// MARK: - JSON-RPC Response Router

private final class JSONRPCResponseRouter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = String
    
    private let logger: Logger
    private let decoder = Foundation.JSONDecoder()
    private var pendingRequests: [JSONRPCIdentifier: Any] = [:]
    private var anyResponseWaiters: [Any] = []
    private let lock = NSLock()
    private var eventLoop: EventLoop?
    private let eventLoopGroup: EventLoopGroup
    
    init(logger: Logger, eventLoopGroup: EventLoopGroup) {
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        eventLoop = context.eventLoop
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        logger.debug("Received raw message: \(message)")
        
        guard let messageData = message.data(using: .utf8) else {
            logger.error("Failed to convert message to UTF-8 data")
            return
        }
        
        do {
            // Parse the JSON to see what kind of message this is
            if let jsonObject = try JSONSerialization.jsonObject(with: messageData, options: []) as? [String: Any] {
                
                // Check if this is a response (has an "id" field)
                if let idValue = jsonObject["id"] {
                    let responseId: JSONRPCIdentifier
                    if let idNumber = idValue as? Int {
                        responseId = .number(idNumber)
                    } else if let idString = idValue as? String {
                        responseId = .string(idString)
                    } else {
                        logger.debug("Received message with invalid ID type, ignoring")
                        return
                    }
                    
                    logger.debug("Processing response for request ID: \(responseId)")
                    handleResponse(responseId: responseId, messageData: messageData)
                } else {
                    // No ID field - this might be a notification or monitoring update
                    logger.debug("Received message without ID (likely notification), forwarding to any-response waiters")
                    handleAnyResponse(messageData: messageData)
                }
            }
        } catch {
            logger.error("Failed to parse JSON message: \(error)")
        }
    }
    
    private func handleResponse(responseId: JSONRPCIdentifier, messageData: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        if let pendingRequestAny = pendingRequests.removeValue(forKey: responseId),
           let pendingRequest = pendingRequestAny as? PendingRequestProtocol {
            logger.debug("Found matching pending request for ID: \(responseId)")
            pendingRequest.timeoutTask.cancel()
            pendingRequest.fulfill(with: messageData, decoder: decoder)
        } else {
            logger.debug("No pending request found for response ID: \(responseId)")
        }
    }
    
    private func handleAnyResponse(messageData: Data) {
        lock.lock()
        let waiters = anyResponseWaiters
        anyResponseWaiters.removeAll()
        lock.unlock()
        
        for waiterAny in waiters {
            if let waiter = waiterAny as? AnyResponseWaiterProtocol {
                waiter.timeoutTask.cancel()
                waiter.fulfill(with: messageData, decoder: decoder)
            }
        }
    }
    
    func waitForResponse<T: Codable>(requestId: JSONRPCIdentifier, type: T.Type, timeout: TimeAmount) -> EventLoopFuture<T> {
        guard let eventLoop = eventLoop else {
            let failedPromise = eventLoopGroup.next().makePromise(of: T.self)
            failedPromise.fail(OVNManagerError.connectionFailed("Event loop not available"))
            return failedPromise.futureResult
        }
        
        let promise = eventLoop.makePromise(of: T.self)
        
        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            self.lock.lock()
            self.pendingRequests.removeValue(forKey: requestId)
            self.lock.unlock()
            promise.fail(OVNManagerError.timeoutError)
        }
        
        let pendingRequest = PendingRequestWrapper<T>(
            promise: promise,
            timeoutTask: timeoutTask
        )
        
        lock.lock()
        pendingRequests[requestId] = pendingRequest
        lock.unlock()
        
        logger.debug("Added pending request for ID: \(requestId)")
        
        return promise.futureResult
    }
    
    func waitForAnyResponse<T: Codable>(type: T.Type, timeout: TimeAmount) -> EventLoopFuture<T> {
        guard let eventLoop = eventLoop else {
            let failedPromise = eventLoopGroup.next().makePromise(of: T.self)
            failedPromise.fail(OVNManagerError.connectionFailed("Event loop not available"))
            return failedPromise.futureResult
        }
        
        let promise = eventLoop.makePromise(of: T.self)
        
        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            self.lock.lock()
            defer { self.lock.unlock() }
            promise.fail(OVNManagerError.timeoutError)
        }
        
        let waiter = AnyResponseWaiterWrapper<T>(
            promise: promise,
            timeoutTask: timeoutTask
        )
        
        lock.lock()
        anyResponseWaiters.append(waiter)
        lock.unlock()
        
        return promise.futureResult
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Channel error caught: \(error)")
        
        lock.lock()
        let allPendingRequests = Array(pendingRequests.values)
        let allWaiters = anyResponseWaiters
        pendingRequests.removeAll()
        anyResponseWaiters.removeAll()
        lock.unlock()
        
        for requestAny in allPendingRequests {
            if let request = requestAny as? PendingRequestProtocol {
                request.timeoutTask.cancel()
                request.fail(with: error)
            }
        }
        
        for waiterAny in allWaiters {
            if let waiter = waiterAny as? AnyResponseWaiterProtocol {
                waiter.timeoutTask.cancel()
                waiter.fail(with: error)
            }
        }
    }
}

private protocol PendingRequestProtocol {
    var timeoutTask: Scheduled<Void> { get }
    func fulfill(with data: Data, decoder: JSONDecoder)
    func fail(with error: Error)
}

private protocol AnyResponseWaiterProtocol {
    var timeoutTask: Scheduled<Void> { get }
    func fulfill(with data: Data, decoder: JSONDecoder)
    func fail(with error: Error)
}

private struct PendingRequestWrapper<T: Codable>: PendingRequestProtocol {
    let promise: EventLoopPromise<T>
    let timeoutTask: Scheduled<Void>
    
    func fulfill(with data: Data, decoder: JSONDecoder) {
        do {
            let response = try decoder.decode(T.self, from: data)
            promise.succeed(response)
        } catch {
            promise.fail(OVNManagerError.decodingError(error))
        }
    }
    
    func fail(with error: Error) {
        promise.fail(error)
    }
}

private struct AnyResponseWaiterWrapper<T: Codable>: AnyResponseWaiterProtocol {
    let promise: EventLoopPromise<T>
    let timeoutTask: Scheduled<Void>
    
    func fulfill(with data: Data, decoder: JSONDecoder) {
        do {
            let response = try decoder.decode(T.self, from: data)
            promise.succeed(response)
        } catch {
            promise.fail(OVNManagerError.decodingError(error))
        }
    }
    
    func fail(with error: Error) {
        promise.fail(error)
    }
}

// MARK: - Frame Handling

private final class LineDelimitedFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = String
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Look for a newline in the buffer
        if let newlineIndex = buffer.withUnsafeReadableBytes({ bytes in
            bytes.firstIndex(of: UInt8(ascii: "\n"))
        }) {
            // Read up to and including the newline
            guard let line = buffer.readString(length: newlineIndex + 1) else {
                return .needMoreData
            }
            
            // Trim whitespace and newlines, then fire the message
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                context.fireChannelRead(wrapInboundOut(trimmed))
            }
            
            // Continue processing if there's more data
            return .continue
        }
        
        // No newline found, but if we have JSON-like content, try to process it
        if buffer.readableBytes > 0 {
            if let content = buffer.getString(at: 0, length: buffer.readableBytes),
               content.hasPrefix("{") && content.hasSuffix("}") {
                // This looks like complete JSON, process it
                buffer.moveReaderIndex(to: buffer.writerIndex) // consume all bytes
                context.fireChannelRead(wrapInboundOut(content))
                return .continue
            }
        }
        
        // No complete line yet, wait for more data
        return .needMoreData
    }
}

private final class StringToByteEncoder: MessageToByteEncoder {
    typealias OutboundIn = String
    
    func encode(data: String, out: inout ByteBuffer) throws {
        out.writeString(data)
    }
}