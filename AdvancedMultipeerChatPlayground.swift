import SwiftUI
import MultipeerConnectivity
import Network
import CryptoKit
import PlaygroundSupport

/*
 AdvancedMultipeerChatPlayground.swift
 ------------------------------------
 Drop this entire file into a new iPad / iOS Swift Playground page.

 Required playground settings / capabilities:
 1) Platform: iOS / iPadOS Playground
 2) App allows Local Network access
 3) If prompted, allow Nearby Devices + Local Network permissions

 Notes:
 - MultipeerConnectivity already encrypts transport when encryptionPreference = .required.
 - This sample ALSO supports optional app-layer AES.GCM payload encryption.
 - Every peer must use the same passphrase when app-layer encryption is enabled.
*/

// MARK: - Message Models

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case text
        case typing
        case deliveryReceipt
        case system
        case heartbeat
    }

    let id: UUID
    let roomID: String
    let senderID: String
    let senderName: String
    let timestamp: Date
    let kind: Kind
    let body: String
    let replyTo: UUID?

    init(
        id: UUID = UUID(),
        roomID: String,
        senderID: String,
        senderName: String,
        timestamp: Date = .now,
        kind: Kind,
        body: String,
        replyTo: UUID? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
        self.replyTo = replyTo
    }
}

struct MessageEnvelope: Codable {
    enum Payload: Codable {
        case hello(name: String, roomID: String)
        case chat(ChatMessage)

        private enum CodingKeys: String, CodingKey {
            case type, name, roomID, chat
        }

        private enum PayloadType: String, Codable {
            case hello, chat
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(PayloadType.self, forKey: .type) {
            case .hello:
                self = .hello(
                    name: try c.decode(String.self, forKey: .name),
                    roomID: try c.decode(String.self, forKey: .roomID)
                )
            case .chat:
                self = .chat(try c.decode(ChatMessage.self, forKey: .chat))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .hello(let name, let roomID):
                try c.encode(PayloadType.hello, forKey: .type)
                try c.encode(name, forKey: .name)
                try c.encode(roomID, forKey: .roomID)
            case .chat(let message):
                try c.encode(PayloadType.chat, forKey: .type)
                try c.encode(message, forKey: .chat)
            }
        }
    }

    let payload: Payload
    let sentAt: Date

    init(payload: Payload, sentAt: Date = .now) {
        self.payload = payload
        self.sentAt = sentAt
    }
}

// MARK: - Optional App-Layer Encryption

struct CryptoBox {
    private let key: SymmetricKey

    init(passphrase: String) {
        let digest = SHA256.hash(data: Data(passphrase.utf8))
        self.key = SymmetricKey(data: digest)
    }

    func encrypt(_ input: Data) throws -> Data {
        let sealed = try AES.GCM.seal(input, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "CryptoBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to combine cipher payload"])
        }
        return combined
    }

    func decrypt(_ input: Data) throws -> Data {
        let sealed = try AES.GCM.SealedBox(combined: input)
        return try AES.GCM.open(sealed, using: key)
    }
}

// MARK: - Service

@MainActor
final class PlaygroundP2PChatService: NSObject, ObservableObject {
    static let serviceType = "advchatv2" // <= 15 chars

    @Published var roomID: String = "global"
    @Published var draft: String = ""
    @Published var encryptionEnabled = false
    @Published var passphrase: String = "playground-secret"

    @Published private(set) var discoveredPeers: [MCPeerID] = []
    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var localNetworkServices: [String] = []

    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private var bonjourBrowser: NWBrowser?
    private var seenIDs: Set<UUID> = []

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(displayName: String = UIDevice.current.name) {
        myPeerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["room": "1"], serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startBonjourScan()
        appendSystem("Started as \(myPeerID.displayName)")
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        bonjourBrowser?.cancel()
        bonjourBrowser = nil
        session.disconnect()
        appendSystem("Stopped")
    }

    func connect(_ peer: MCPeerID) {
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
        appendSystem("Invited \(peer.displayName)")
    }

    func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let message = ChatMessage(
            roomID: roomID,
            senderID: myPeerID.displayName,
            senderName: myPeerID.displayName,
            kind: .text,
            body: text
        )

        draft = ""
        ingest(message, shouldAcknowledge: false)
        Task { await broadcast(.chat(message)) }
    }

    func sendTypingSignal() {
        let typing = ChatMessage(
            roomID: roomID,
            senderID: myPeerID.displayName,
            senderName: myPeerID.displayName,
            kind: .typing,
            body: "typing..."
        )
        Task { await broadcast(.chat(typing)) }
    }

    private func broadcast(_ payload: MessageEnvelope.Payload) async {
        guard !session.connectedPeers.isEmpty else { return }
        do {
            let data = try encoder.encode(MessageEnvelope(payload: payload))
            let out = try encodePayloadIfNeeded(data)
            try session.send(out, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            appendSystem("Send error: \(error.localizedDescription)")
        }
    }

    private func handleIncoming(_ input: Data, from peer: MCPeerID) {
        do {
            let raw = try decodePayloadIfNeeded(input)
            let envelope = try decoder.decode(MessageEnvelope.self, from: raw)
            switch envelope.payload {
            case .hello(let name, let remoteRoom):
                appendSystem("👋 \(name) joined room '\(remoteRoom)' from \(peer.displayName)")
            case .chat(let message):
                guard message.roomID == roomID else { return }
                ingest(message, shouldAcknowledge: message.kind == .text)
            }
        } catch {
            appendSystem("Receive error from \(peer.displayName): \(error.localizedDescription)")
        }
    }

    private func ingest(_ message: ChatMessage, shouldAcknowledge: Bool) {
        guard !seenIDs.contains(message.id) else { return }
        seenIDs.insert(message.id)

        switch message.kind {
        case .typing:
            messages.removeAll { $0.kind == .typing && $0.senderID == message.senderID }
            messages.append(message)
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                messages.removeAll { $0.kind == .typing && $0.senderID == message.senderID }
            }
        case .heartbeat:
            break
        case .text, .system, .deliveryReceipt:
            messages.append(message)
        }

        if shouldAcknowledge, message.senderID != myPeerID.displayName {
            let receipt = ChatMessage(
                roomID: roomID,
                senderID: myPeerID.displayName,
                senderName: myPeerID.displayName,
                kind: .deliveryReceipt,
                body: "Delivered",
                replyTo: message.id
            )
            Task { await broadcast(.chat(receipt)) }
        }
    }

    private func appendSystem(_ text: String) {
        let message = ChatMessage(
            roomID: roomID,
            senderID: "system",
            senderName: "System",
            kind: .system,
            body: text
        )
        ingest(message, shouldAcknowledge: false)
    }

    private func encodePayloadIfNeeded(_ data: Data) throws -> Data {
        guard encryptionEnabled else { return data }
        return try CryptoBox(passphrase: passphrase).encrypt(data)
    }

    private func decodePayloadIfNeeded(_ data: Data) throws -> Data {
        guard encryptionEnabled else { return data }
        return try CryptoBox(passphrase: passphrase).decrypt(data)
    }

    private func startBonjourScan() {
        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_\(Self.serviceType)._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        bonjourBrowser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.localNetworkServices = results.map { "\($0.endpoint)" }.sorted()
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state {
                    self?.appendSystem("Bonjour scan failed: \(error.localizedDescription)")
                }
            }
        }

        browser.start(queue: .main)
    }
}

// MARK: - Delegates

extension PlaygroundP2PChatService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.connectedPeers = session.connectedPeers

            switch state {
            case .notConnected:
                self.appendSystem("Disconnected: \(peerID.displayName)")
            case .connecting:
                self.appendSystem("Connecting: \(peerID.displayName)")
            case .connected:
                self.appendSystem("Connected: \(peerID.displayName)")
                await self.broadcast(.hello(name: self.myPeerID.displayName, roomID: self.roomID))
            @unknown default:
                self.appendSystem("Unknown session state for \(peerID.displayName)")
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleIncoming(data, from: peerID)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}

extension PlaygroundP2PChatService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        invitationHandler(true, session)
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.appendSystem("Advertising failed: \(error.localizedDescription)")
        }
    }
}

extension PlaygroundP2PChatService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String : String]?
    ) {
        Task { @MainActor in
            guard peerID != self.myPeerID else { return }
            if !self.discoveredPeers.contains(peerID) {
                self.discoveredPeers.append(peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredPeers.removeAll { $0 == peerID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.appendSystem("Browsing failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - UI

struct ChatBubble: View {
    let message: ChatMessage
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer() }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.senderName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.body)
                    .padding(10)
                    .background(mine ? .blue.opacity(0.2) : .gray.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !mine { Spacer() }
        }
    }
}

struct PlaygroundChatRootView: View {
    @StateObject private var service = PlaygroundP2PChatService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack {
                    TextField("Room (same value across devices)", text: $service.roomID)
                        .textFieldStyle(.roundedBorder)
                    Button("Start") { service.start() }
                        .buttonStyle(.borderedProminent)
                    Button("Stop") { service.stop() }
                        .buttonStyle(.bordered)
                }

                GroupBox("Discovered Peers") {
                    if service.discoveredPeers.isEmpty {
                        Text("No peers yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(service.discoveredPeers, id: \.self) { peer in
                            HStack {
                                Text(peer.displayName)
                                Spacer()
                                Button("Connect") { service.connect(peer) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

                GroupBox("Connected") {
                    Text(service.connectedPeers.map(\.displayName).joined(separator: ", ").or("none"))
                }

                GroupBox("Local Network Services") {
                    if service.localNetworkServices.isEmpty {
                        Text("No Bonjour services visible")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(service.localNetworkServices, id: \.self) { item in
                            Text(item)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Toggle("Enable app-layer AES.GCM encryption", isOn: $service.encryptionEnabled)
                TextField("Shared passphrase", text: $service.passphrase)
                    .textFieldStyle(.roundedBorder)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(service.messages) { message in
                                ChatBubble(
                                    message: message,
                                    mine: message.senderID == UIDevice.current.name
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .onChange(of: service.messages.count) { _, _ in
                        if let id = service.messages.last?.id {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }

                HStack {
                    TextField("Message", text: $service.draft)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: service.draft) { _, text in
                            if !text.isEmpty { service.sendTypingSignal() }
                        }
                    Button("Send") { service.sendText() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Advanced Local P2P Chat")
        }
    }
}

private extension String {
    func or(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

let root = PlaygroundChatRootView()
PlaygroundPage.current.setLiveView(root)
