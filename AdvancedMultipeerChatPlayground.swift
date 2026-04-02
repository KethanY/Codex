import SwiftUI
import MultipeerConnectivity
import Network
import CryptoKit

// MARK: - Models

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case text
        case typing
        case deliveryReceipt
        case system
    }

    let id: UUID
    let senderID: String
    let senderName: String
    let timestamp: Date
    let kind: Kind
    let body: String
    let replyTo: UUID?

    init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        timestamp: Date = .now,
        kind: Kind,
        body: String,
        replyTo: UUID? = nil
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
        self.replyTo = replyTo
    }
}

struct Envelope: Codable {
    enum Payload: Codable {
        case chat(ChatMessage)
        case hello(deviceName: String)

        enum CodingKeys: String, CodingKey {
            case type, chat, deviceName
        }

        enum PayloadType: String, Codable {
            case chat, hello
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(PayloadType.self, forKey: .type)
            switch type {
            case .chat:
                self = .chat(try container.decode(ChatMessage.self, forKey: .chat))
            case .hello:
                self = .hello(deviceName: try container.decode(String.self, forKey: .deviceName))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .chat(let message):
                try container.encode(PayloadType.chat, forKey: .type)
                try container.encode(message, forKey: .chat)
            case .hello(let name):
                try container.encode(PayloadType.hello, forKey: .type)
                try container.encode(name, forKey: .deviceName)
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

// MARK: - Crypto Helper (optional E2E layer)

struct CryptoBox {
    private let key: SymmetricKey

    init(passphrase: String) {
        let digest = SHA256.hash(data: Data(passphrase.utf8))
        self.key = SymmetricKey(data: digest)
    }

    func seal(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "CryptoBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to combine sealed data"])
        }
        return combined
    }

    func open(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }
}

// MARK: - Service Layer

@MainActor
final class AdvancedMultipeerChatService: NSObject, ObservableObject {
    // Keep <= 15 chars and lowercase for Multipeer service type
    static let serviceType = "adv-chat-v1"

    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published var typedText: String = ""
    @Published var isEncryptionEnabled: Bool = true
    @Published var passphrase: String = "playgrounds-secret"

    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    // Network framework browser to demonstrate local network visibility with Bonjour
    private var nwBrowser: NWBrowser?
    @Published private(set) var bonjourServices: [String] = []

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Message IDs we already processed to avoid duplicate inserts from multiple paths
    private var seenMessageIDs: Set<UUID> = []

    init(displayName: String = UIDevice.current.name) {
        self.myPeerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["v": "1"], serviceType: Self.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startBonjourVisibilityBrowser()

        appendSystem("Started as \(myPeerID.displayName). Discovering peers on local network…")
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        nwBrowser?.cancel()
        nwBrowser = nil
        session.disconnect()

        appendSystem("Stopped networking.")
    }

    func connect(to peer: MCPeerID) {
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
        appendSystem("Sent invite to \(peer.displayName)")
    }

    func sendText() {
        let trimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let msg = ChatMessage(
            senderID: myPeerID.displayName,
            senderName: myPeerID.displayName,
            kind: .text,
            body: trimmed
        )
        typedText = ""
        ingest(message: msg, sendReceipt: false)
        Task { await broadcast(.chat(msg)) }
    }

    func sendTypingIndicator() {
        let indicator = ChatMessage(
            senderID: myPeerID.displayName,
            senderName: myPeerID.displayName,
            kind: .typing,
            body: "…typing"
        )
        Task { await broadcast(.chat(indicator)) }
    }

    private func ingest(message: ChatMessage, sendReceipt: Bool) {
        guard !seenMessageIDs.contains(message.id) else { return }
        seenMessageIDs.insert(message.id)

        switch message.kind {
        case .text, .system, .deliveryReceipt:
            messages.append(message)
        case .typing:
            // Keep only the latest typing indicator for each peer
            messages.removeAll { $0.kind == .typing && $0.senderID == message.senderID }
            messages.append(message)
        }

        // Trim old typing indicators after a short period
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            messages.removeAll { $0.kind == .typing && $0.senderID == message.senderID }
        }

        if sendReceipt, message.kind == .text {
            let receipt = ChatMessage(
                senderID: myPeerID.displayName,
                senderName: myPeerID.displayName,
                kind: .deliveryReceipt,
                body: "Delivered",
                replyTo: message.id
            )
            Task { await broadcast(.chat(receipt)) }
        }
    }

    private func broadcast(_ payload: Envelope.Payload) async {
        guard !session.connectedPeers.isEmpty else { return }

        let envelope = Envelope(payload: payload)
        do {
            let raw = try encoder.encode(envelope)
            let data = try encryptIfNeeded(raw)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            appendSystem("Send failed: \(error.localizedDescription)")
        }
    }

    private func handleIncoming(_ data: Data, from peerID: MCPeerID) {
        do {
            let plain = try decryptIfNeeded(data)
            let envelope = try decoder.decode(Envelope.self, from: plain)
            switch envelope.payload {
            case .chat(let message):
                ingest(message: message, sendReceipt: message.senderID != myPeerID.displayName)
            case .hello(let name):
                appendSystem("👋 Hello from \(name) [\(peerID.displayName)]")
            }
        } catch {
            appendSystem("Decode failed from \(peerID.displayName): \(error.localizedDescription)")
        }
    }

    private func encryptIfNeeded(_ data: Data) throws -> Data {
        guard isEncryptionEnabled else { return data }
        return try CryptoBox(passphrase: passphrase).seal(data)
    }

    private func decryptIfNeeded(_ data: Data) throws -> Data {
        guard isEncryptionEnabled else { return data }
        return try CryptoBox(passphrase: passphrase).open(data)
    }

    private func appendSystem(_ text: String) {
        let msg = ChatMessage(
            senderID: "system",
            senderName: "System",
            kind: .system,
            body: text
        )
        ingest(message: msg, sendReceipt: false)
    }

    private func startBonjourVisibilityBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_\(Self.serviceType)._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        nwBrowser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.bonjourServices = results.map { "\($0.endpoint)" }.sorted()
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.appendSystem("Bonjour browser ready.")
                case .failed(let error):
                    self?.appendSystem("Bonjour browser failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }

        browser.start(queue: .main)
    }
}

// MARK: - Delegates

extension AdvancedMultipeerChatService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.connectedPeers = session.connectedPeers
            let text: String
            switch state {
            case .notConnected: text = "Disconnected: \(peerID.displayName)"
            case .connecting: text = "Connecting: \(peerID.displayName)"
            case .connected:
                text = "Connected: \(peerID.displayName)"
                await self.broadcast(.hello(deviceName: self.myPeerID.displayName))
            @unknown default: text = "Unknown state: \(peerID.displayName)"
            }
            self.appendSystem(text)
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

extension AdvancedMultipeerChatService: MCNearbyServiceAdvertiserDelegate {
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

extension AdvancedMultipeerChatService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor in
            guard peerID != self.myPeerID else { return }
            if !self.peers.contains(peerID) {
                self.peers.append(peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.peers.removeAll { $0 == peerID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.appendSystem("Browsing failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - UI

struct ChatRow: View {
    let message: ChatMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer() }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.senderName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.body)
                    .padding(10)
                    .background(isMine ? .blue.opacity(0.2) : .gray.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isMine { Spacer() }
        }
    }
}

struct ContentView: View {
    @StateObject private var service = AdvancedMultipeerChatService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GroupBox("Peers") {
                    if service.peers.isEmpty {
                        Text("No peers discovered yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(service.peers, id: \.self) { peer in
                            HStack {
                                Text(peer.displayName)
                                Spacer()
                                Button("Connect") {
                                    service.connect(to: peer)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

                GroupBox("Connected") {
                    Text(service.connectedPeers.map(\.displayName).joined(separator: ", ").ifEmpty("none"))
                }

                GroupBox("Local Network (Bonjour)") {
                    if service.bonjourServices.isEmpty {
                        Text("No local services visible")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(service.bonjourServices, id: \.self) { item in
                            Text(item)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Toggle("Enable app-level encryption (AES.GCM)", isOn: $service.isEncryptionEnabled)
                TextField("Shared passphrase", text: $service.passphrase)
                    .textFieldStyle(.roundedBorder)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(service.messages) { message in
                                ChatRow(
                                    message: message,
                                    isMine: message.senderID == UIDevice.current.name
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .onChange(of: service.messages.count) { _, _ in
                        if let last = service.messages.last?.id {
                            withAnimation {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }

                HStack {
                    TextField("Type message", text: $service.typedText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: service.typedText) { _, newValue in
                            if !newValue.isEmpty {
                                service.sendTypingIndicator()
                            }
                        }

                    Button("Send") {
                        service.sendText()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Advanced P2P Chat")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Start") { service.start() }
                    Button("Stop") { service.stop() }
                }
            }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

#Preview {
    ContentView()
}
