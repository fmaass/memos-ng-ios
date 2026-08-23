import Foundation
import MemosAPI
import Testing

@Suite("ServerConfiguration")
struct ServerConfigurationTests {
    @Test("adds https to a bare host")
    func addsScheme() throws {
        let configuration = try #require(ServerConfiguration(serverAddress: "memos.example.com"))
        #expect(configuration.baseURL.absoluteString == "https://memos.example.com")
    }

    @Test("drops a trailing slash and any path so request paths stay absolute")
    func normalisesPath() throws {
        let address = "https://memos.example.com/"
        let configuration = try #require(ServerConfiguration(serverAddress: address))
        #expect(configuration.baseURL.absoluteString == "https://memos.example.com")

        let pathAddress = "https://memos.example.com/app/"
        let withPath = try #require(ServerConfiguration(serverAddress: pathAddress))
        #expect(withPath.baseURL.absoluteString == "https://memos.example.com")
    }

    @Test("keeps a non-default port")
    func keepsPort() throws {
        let address = "memos.example.com:8443"
        let configuration = try #require(ServerConfiguration(serverAddress: address))
        #expect(configuration.baseURL.absoluteString == "https://memos.example.com:8443")
    }

    @Test("refuses plain http, which would put the token on the wire in clear text")
    func refusesInsecureScheme() {
        #expect(ServerConfiguration(serverAddress: "http://memos.example.com") == nil)
    }

    @Test("refuses input that is not an address")
    func refusesJunk() {
        #expect(ServerConfiguration(serverAddress: "") == nil)
        #expect(ServerConfiguration(serverAddress: "   ") == nil)
        #expect(ServerConfiguration(serverAddress: "https://") == nil)
        #expect(ServerConfiguration(serverAddress: "ftp://memos.example.com") == nil)
    }

    @Test("trims surrounding whitespace from a pasted address")
    func trimsWhitespace() throws {
        let address = "  memos.example.com \n"
        let configuration = try #require(ServerConfiguration(serverAddress: address))
        #expect(configuration.baseURL.absoluteString == "https://memos.example.com")
    }
}
