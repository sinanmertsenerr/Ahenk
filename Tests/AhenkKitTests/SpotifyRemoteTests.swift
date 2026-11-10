import Foundation
import Testing
@testable import AhenkKit

@Suite("Starting a song through Spotify's remote")
struct SpotifyRemoteTests {
    static let session = SpotifyRemote.Session(accessToken: "token", clientToken: "client", isSignedIn: true, expiresAt: nil)
    static let own = "8d80c2890bddc2108ad5a1e9a1a07bd4"
    static let mac = "0c077ada6e7d01e2f56a3dec7d59b656e8aa91c1"

    @Test("The page's session is read with its sign-in and its end")
    func sessionFromPage() {
        let text = #"{"clientToken":"client","session":{"accessToken":"abc","accessTokenExpirationTimestampMs":1794346651000,"isAnonymous":false}}"#
        let session = SpotifyRemote.session(fromJSON: text)
        #expect(session?.accessToken == "abc")
        #expect(session?.clientToken == "client")
        #expect(session?.isSignedIn == true)
        #expect(session?.expiresAt == Date(timeIntervalSince1970: 1_794_346_651))
        #expect(session?.isFresh(at: Date(timeIntervalSince1970: 1_794_346_000)) == true)
        #expect(session?.isFresh(at: Date(timeIntervalSince1970: 1_794_346_620)) == false)
    }

    @Test("A visitor's session is not a sign-in; a page that has not asked yet has none")
    func anonymousSession() {
        #expect(SpotifyRemote.session(fromJSON: #"{"session":{"accessToken":"abc","isAnonymous":true}}"#)?.isSignedIn == false)
        #expect(SpotifyRemote.session(fromJSON: #"{"session":{"accessToken":"abc"}}"#)?.isSignedIn == false)
        #expect(SpotifyRemote.session(fromJSON: "{}") == nil)
        #expect(SpotifyRemote.session(fromJSON: "nonsense") == nil)
    }

    @Test("The connection ID comes from the socket's first message")
    func connectionID() {
        let message = #"{"type":"message","headers":{"Spotify-Connection-Id":"abc=="},"method":"PUT"}"#
        #expect(SpotifyRemote.connectionID(fromDealerMessage: message) == "abc==")
        #expect(SpotifyRemote.connectionID(fromDealerMessage: #"{"type":"pong"}"#) == nil)
    }

    @Test("The song goes to the Spotify app on this Mac")
    func target() {
        let devices = [
            SpotifyRemote.Device(id: Self.own, name: "Ahenk", type: "COMPUTER"),
            SpotifyRemote.Device(id: Self.mac, name: "Sinan MacBook Pro", type: "COMPUTER"),
            SpotifyRemote.Device(id: "b95c8f3f756c78c3fd328c2f29d5202765f275a2", name: "Web Player (Safari)", type: "COMPUTER"),
            SpotifyRemote.Device(id: "aaaa8f3f756c78c3fd328c2f29d5202765f275a2", name: "iPhone", type: "SMARTPHONE"),
        ]
        #expect(SpotifyRemote.target(in: devices, computerName: "Sinan MacBook Pro", ownDeviceID: Self.own) == Self.mac)
        // Renamed: still the only Spotify app on a computer.
        #expect(SpotifyRemote.target(in: devices, computerName: "Other", ownDeviceID: Self.own) == Self.mac)
    }

    @Test("Never a phone, and never a guess between two computers")
    func noTarget() {
        let phone = SpotifyRemote.Device(id: "aaaa8f3f756c78c3fd328c2f29d5202765f275a2", name: "iPhone", type: "SMARTPHONE")
        let first = SpotifyRemote.Device(id: Self.mac, name: "Work Mac", type: "COMPUTER")
        let second = SpotifyRemote.Device(id: "cccc8f3f756c78c3fd328c2f29d5202765f275a2", name: "Home PC", type: "COMPUTER")
        #expect(SpotifyRemote.target(in: [phone], computerName: "iPhone", ownDeviceID: Self.own) == nil)
        #expect(SpotifyRemote.target(in: [first, second], computerName: "Other", ownDeviceID: Self.own) == nil)
        #expect(SpotifyRemote.target(in: [first, second], computerName: "work mac", ownDeviceID: Self.own) == Self.mac)
    }

    @Test("Devices are read from Spotify's answer")
    func devices() {
        let json = #"{"active_device_id":"x","devices":{"0c07":{"device_id":"0c077ada6e7d01e2f56a3dec7d59b656e8aa91c1","name":"Sinan MacBook Pro","device_type":"computer"}}}"#
        #expect(SpotifyRemote.devices(fromJSON: Data(json.utf8)) == [SpotifyRemote.Device(id: Self.mac, name: "Sinan MacBook Pro", type: "COMPUTER")])
        #expect(SpotifyRemote.devices(fromJSON: Data("{}".utf8)) == nil)
    }

    @Test("The play command names the song, the remote and the app")
    func playRequest() throws {
        let request = try #require(SpotifyRemote.playRequest(
            session: Self.session, trackID: "7hQJA50XrCWABAu5v6QZ4i", from: Self.own, to: Self.mac, commandID: "c1"
        ))
        #expect(request.url?.absoluteString == "https://gue1-spclient.spotify.com/connect-state/v1/player/command/from/\(Self.own)/to/\(Self.mac)")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "client-token") == "client")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let command = try #require(body["command"] as? [String: Any])
        #expect(command["endpoint"] as? String == "play")
        #expect((command["context"] as? [String: Any])?["uri"] as? String == "spotify:track:7hQJA50XrCWABAu5v6QZ4i")
    }

    @Test("Nothing is sent for an ID that is not one")
    func badIDs() {
        #expect(SpotifyRemote.playRequest(session: Self.session, trackID: "x\" y", from: Self.own, to: Self.mac, commandID: "c") == nil)
        #expect(SpotifyRemote.playRequest(session: Self.session, trackID: "7hQJA50XrCWABAu5v6QZ4i", from: Self.own, to: "../x", commandID: "c") == nil)
        #expect(SpotifyRemote.stateRequest(session: Self.session, deviceID: "a/b", connectionID: "c") == nil)
        #expect(SpotifyRemote.randomID().count == 32)
    }

    @Test("Liked Songs are asked and changed by the account's user name")
    func likedSongs() throws {
        var session = Self.session
        #expect(SpotifyRemote.likedRequest(session: session, trackID: "7hQJA50XrCWABAu5v6QZ4i") == nil, "no user name, no request")
        session.username = "clis16rgm683"
        let ask = try #require(SpotifyRemote.likedRequest(session: session, trackID: "7hQJA50XrCWABAu5v6QZ4i"))
        #expect(ask.url?.absoluteString == "https://spclient.wg.spotify.com/collection/v2/contains?market=from_token")
        let askedBody = try #require(ask.httpBody)
        let asked = try #require(try JSONSerialization.jsonObject(with: askedBody) as? [String: Any])
        #expect(asked["username"] as? String == "clis16rgm683")
        #expect(asked["set"] as? String == "collection")
        #expect((asked["items"] as? [[String: Any]])?.first?["uri"] as? String == "spotify:track:7hQJA50XrCWABAu5v6QZ4i")
        #expect(SpotifyRemote.isLiked(fromJSON: Data(#"{"found": [true]}"#.utf8)) == true)
        #expect(SpotifyRemote.isLiked(fromJSON: Data(#"{"found": [false]}"#.utf8)) == false)
        #expect(SpotifyRemote.isLiked(fromJSON: Data("{}".utf8)) == nil)

        let date = Date(timeIntervalSince1970: 1_794_000_000)
        let add = try #require(SpotifyRemote.likeRequest(session: session, trackID: "7hQJA50XrCWABAu5v6QZ4i", liked: true, at: date))
        #expect(add.url?.absoluteString == "https://spclient.wg.spotify.com/collection/v2/write?market=from_token")
        let addedBody = try #require(add.httpBody)
        let added = try #require(try JSONSerialization.jsonObject(with: addedBody) as? [String: Any])
        #expect((added["items"] as? [[String: Any]])?.first?["addedAt"] as? Int == 1_794_000_000)
        let remove = try #require(SpotifyRemote.likeRequest(session: session, trackID: "7hQJA50XrCWABAu5v6QZ4i", liked: false, at: date))
        let removedBody = try #require(remove.httpBody)
        let removed = try #require(try JSONSerialization.jsonObject(with: removedBody) as? [String: Any])
        #expect((removed["items"] as? [[String: Any]])?.first?["isRemoved"] as? Bool == true)
        session.username = "a/b"
        #expect(SpotifyRemote.likeRequest(session: session, trackID: "7hQJA50XrCWABAu5v6QZ4i", liked: true, at: date) == nil)
    }

    @Test("The page's session carries the account's user name when the page named it")
    func username() {
        let text = #"{"username":"clis16rgm683","session":{"accessToken":"abc","isAnonymous":false}}"#
        #expect(SpotifyRemote.session(fromJSON: text)?.username == "clis16rgm683")
        #expect(SpotifyRemote.session(fromJSON: #"{"username":"a b","session":{"accessToken":"abc"}}"#)?.username == nil)
    }
}
