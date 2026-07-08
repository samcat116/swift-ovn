import XCTest
import NIO
import NIOPosix
import NIOSSL
import Logging
@testable import SwiftOVN

/// End-to-end tests for the `ssl:` transport against an in-process NIOSSL
/// server using a self-signed certificate whose SANs cover `localhost` and
/// `127.0.0.1`. Also verifies that `connect()` reflects the TLS handshake
/// outcome instead of resolving at TCP establishment.
final class TLSTransportTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!
    private var caFilePath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // The client API takes the CA as a PEM file path.
        let caFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftovn-test-ca-\(UUID().uuidString).pem")
        try Self.certificatePEM.write(to: caFile, atomically: true, encoding: .utf8)
        caFilePath = caFile.path
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        group = nil
        if let caFilePath {
            try? FileManager.default.removeItem(atPath: caFilePath)
        }
        caFilePath = nil
        super.tearDown()
    }

    private func startTLSServer() async throws -> Channel {
        let certificate = try NIOSSLCertificate(bytes: Array(Self.certificatePEM.utf8), format: .pem)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(Self.privateKeyPEM.utf8), format: .pem)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        let sslContext = try NIOSSLContext(configuration: configuration)

        return try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSLServerHandler(context: sslContext),
                    JSONRPCStubServerHandler()
                ])
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func testHandshakeAndEchoWithTrustedCA() async throws {
        // The client connects by IP with no serverHostname, so a passing
        // handshake also proves NIOSSL's IP-SAN identity verification path.
        let server = try await startTLSServer()
        let port = try XCTUnwrap(server.localAddress?.port)

        let tls = OVSDBTLSConfiguration(caCertificatePath: caFilePath)
        let client = JSONRPCClient(
            endpoint: .ssl(host: "127.0.0.1", port: port, tls: tls),
            eventLoopGroup: group
        )
        try await client.connect()
        XCTAssertTrue(client.isConnected)

        let echoed = try await client.echo()
        XCTAssertEqual(echoed, ["echo"])

        try await client.disconnect()
    }

    func testConnectFailsWhenCertificateIsUntrusted() async throws {
        // Without our CA in the trust roots the handshake must fail, and that
        // failure must surface from connect() itself — not from a later
        // request — since verification happens after the TCP connect.
        let server = try await startTLSServer()
        let port = try XCTUnwrap(server.localAddress?.port)

        let client = JSONRPCClient(
            endpoint: .ssl(host: "127.0.0.1", port: port, tls: OVSDBTLSConfiguration()),
            eventLoopGroup: group
        )
        do {
            try await client.connect()
            XCTFail("Expected TLS handshake to fail against an untrusted certificate")
        } catch {
            guard case OVNManagerError.connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        }
        XCTAssertFalse(client.isConnected)
    }

    func testDisabledVerificationConnects() async throws {
        let server = try await startTLSServer()
        let port = try XCTUnwrap(server.localAddress?.port)

        let tls = OVSDBTLSConfiguration(verifiesServerCertificate: false)
        let client = JSONRPCClient(
            endpoint: .ssl(host: "127.0.0.1", port: port, tls: tls),
            eventLoopGroup: group
        )
        try await client.connect()
        let echoed = try await client.echo()
        XCTAssertEqual(echoed, ["echo"])
        try await client.disconnect()
    }

    // MARK: - Fixtures

    /// Self-signed certificate, CN=localhost, SANs DNS:localhost and
    /// IP:127.0.0.1, valid for 100 years from 2026-07-08.
    private static let certificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIICyzCCAbOgAwIBAgIJAPQPBrejKTVtMA0GCSqGSIb3DQEBCwUAMBQxEjAQBgNV
        BAMMCWxvY2FsaG9zdDAgFw0yNjA3MDgyMjMyNDNaGA8yMTI2MDYxNDIyMzI0M1ow
        FDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
        CgKCAQEA24Kh/EWoassVpdt6xO5hJQeBa1hKHuhz71AjXf1o6KCTcsLGZf9pRi7i
        Rb88qcxaw9TF39BQjF8+JwgMLi1Eu4o9G+jG6mXnUeLjGxKIxLGS+kHAsdaWlE0B
        3vmfFOCQOLkous34ATs9+qznEzC8AJGKqislDbL5TIT2xmvnyN+9Qo/mZa2hoDTL
        22mrSSrtUGnZuRETjh+PiTL1w0C/rxaVTMSi1WQtyuai4axV5mlzEFtHBacsFxwR
        zv6HGeGeZVC9Qmzs99wjPB82de0xPMfxru1pNkQeeC/I1tmo1PX/q9FAqFW/Kzud
        xZcwlKVm9Q5bTxjzv1MwUbYGb1oX2wIDAQABox4wHDAaBgNVHREEEzARgglsb2Nh
        bGhvc3SHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBADhtVmpg+K+fJY9syksBxW/n
        EMC2izoqKyvRcKoTbMlQjxAsMD/NUnqGbERGjXIf3xE5GHBuDsMXP8a4+wnvAmVB
        5m4+CfEoQYzjpmsdi80xIsXf5dDHG4UunVqtaka2sShWSCOsHeV5MshXJUtZZZD8
        ZgaqwR1F2yCM7xlSZQFuXXn15jbljiPTTNZbi1+7JMUJTXzeWxv/SeVOius/dBuo
        9mT78PtzSNuuaDToS2V7Npy3PituT5JHT2vZmgavv5/4lAMwiRbsWD5wNy5b5n6e
        WsYPg0NReXoXiV0mAO54sszjShGbB4qZBhZv1XJJy5Nz90PuF1moeSjf4femERo=
        -----END CERTIFICATE-----
        """

    private static let privateKeyPEM = """
        -----BEGIN PRIVATE KEY-----
        MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDbgqH8RahqyxWl
        23rE7mElB4FrWEoe6HPvUCNd/WjooJNywsZl/2lGLuJFvzypzFrD1MXf0FCMXz4n
        CAwuLUS7ij0b6MbqZedR4uMbEojEsZL6QcCx1paUTQHe+Z8U4JA4uSi6zfgBOz36
        rOcTMLwAkYqqKyUNsvlMhPbGa+fI371Cj+ZlraGgNMvbaatJKu1Qadm5EROOH4+J
        MvXDQL+vFpVMxKLVZC3K5qLhrFXmaXMQW0cFpywXHBHO/ocZ4Z5lUL1CbOz33CM8
        HzZ17TE8x/Gu7Wk2RB54L8jW2ajU9f+r0UCoVb8rO53FlzCUpWb1DltPGPO/UzBR
        tgZvWhfbAgMBAAECggEAYZF9Aq7LnzxJkQEvXp0+XMErS1VhDL/x2CtcrQhYOx40
        q8vbd7bBSkrIlIveIPMOXQEUOtlTFDG5ZIv1Lgk9Bcb6Ro9+6u0ElqcsnvnsBNGR
        LN9RETr6j0xzSnLVvOfb8vqKGg428AUvFV8JDsSYrAAFDIJE5APrP5HSRnvr+KJ3
        hqYqhQivpQg9c3KGG/pcAu2JBsmzC7vhDTzmR9Qj+nODE5yBdPu9iz8w67JemEN/
        D1Ypuh7HHoU8DcWOYjSMwRZG/lahHyTIUiKEqENjY500z/7rrDF5hCKkUPkJ4Wc9
        li04aQ7z5IZ1Aleob+GdObICCNRftYNgWjmIVwmyAQKBgQD3TDKme/o23zolw44P
        qpHV4s3jmmPkUznfMAJNgcLQ/WVWsQ4okPt/izYVcU60rjX1TA1MMWb449Sl4c3Q
        M5cx3Ddc8QfjGX8uxylMQRbbtW7PxhdPJfNowNWuCmoMsrmzNDZhOlLskxbVG2YQ
        SVt1iPl/RVNQ5/ZQKG+EMqwMgQKBgQDjPBwr74IOevSvqFF/H7FCVp+QoYa6lKJU
        SoOju3fjSCaSMRAgFlkn9ODMVkVjrdbMpG2JonzT30dCI3y2ntWjV4ZQXuoLNNb5
        kERVbttCL5WFaproUBKCcwf73hac+ThRV0rgo9pjeyO7vTikWXj3vPmH1waBe3bE
        TmFTSRamWwKBgDNqmlVXDYz/GJ3lbNIBCtVHlLsvzHkafLvUxYXL5u+A3+MIaQMy
        Mbgw/4uxxUV3uyxHJbSjyN8Sr5HVwu746wSo3rHqQ1OKZ5EYQ5PhLJl9vY5hh1Mj
        dtpezY6kB6ygNE/4GR5Z/AfIBUVFrxDPz74+PnGhvlLiB6pe3eDEkFUBAoGAanSr
        wg2YAY6q+WxCmerQEYMhiBGUW+7sSc8K8vcNyIXxxAWGR3IQ3L5FXpWANp2nhwH1
        a0ibcGsnKB4V/DxXXAnSG+8LeKqNmCd1TAz+XXiLdRCnd/SjZ0fa0q2OLIY5Uyox
        IyLAWmDDMd4JHj3ohS+cO36KRrj/wCH0SJ9yJAcCgYAMd0YU/t+lfDngHVYf2osV
        tCRFArFzXqtR+m7jkfI+oi8eWY/CTMswTheW7lTyo32j8UwVrm08mZKCxdk/S/nV
        iSuQFW0+n+jYlQzRLCXyr1Efy9iZWK2ATSXJ9w4KxJvcPeJ4tw3sba1SY5882V7k
        i43Yy+DkAVej08C+p+wExg==
        -----END PRIVATE KEY-----
        """
}
