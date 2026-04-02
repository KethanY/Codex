import UIKit
import PlaygroundSupport
import MultipeerConnectivity

// MARK: - Models

enum PayloadType: String, Codable {
    case text
    case typing
    case receipt
    case reaction
}

enum ReceiptState: String, Codable {
    case sent
    case delivered
    case read
}

struct ChatPayload: Codable {
    let id: UUID
    let conversationID: UUID
    let senderID: String
    let senderName: String
    let timestamp: Date
    let type: PayloadType

    let text: String?
    let targetMessageID: UUID?
    let receiptState: ReceiptState?
    let reaction: String?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        senderID: String,
        senderName: String,
        timestamp: Date = Date(),
        type: PayloadType,
        text: String? = nil,
        targetMessageID: UUID? = nil,
        receiptState: ReceiptState? = nil,
        reaction: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.type = type
        self.text = text
        self.targetMessageID = targetMessageID
        self.receiptState = receiptState
        self.reaction = reaction
    }
}

struct ChatMessage {
    let id: UUID
    let senderID: String
    let senderName: String
    let text: String
    let timestamp: Date
    var receipt: ReceiptState
    var reactions: [String: String]

    var isMe: Bool = false
}

// MARK: - Peer Manager

protocol PeerServiceDelegate: AnyObject {
    func peerService(_ service: PeerService, didReceive payload: ChatPayload)
    func peerService(_ service: PeerService, peersDidChange peers: [MCPeerID])
}

final class PeerService: NSObject {
    static let serviceType = "advmsg-play"

    weak var delegate: PeerServiceDelegate?

    let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    init(displayName: String) {
        myPeerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func send(_ payload: ChatPayload) {
        guard !session.connectedPeers.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(payload)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            print("Send error: \(error)")
        }
    }

    private func updatePeers() {
        delegate?.peerService(self, peersDidChange: session.connectedPeers)
    }
}

extension PeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { self.updatePeers() }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let payload = try? JSONDecoder().decode(ChatPayload.self, from: data) else { return }
        DispatchQueue.main.async {
            self.delegate?.peerService(self, didReceive: payload)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
    func session(_ session: MCSession, didReceive certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}

extension PeerService: MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Advertiser error: \(error)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard peerID != myPeerID else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 12)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.updatePeers() }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("Browser error: \(error)")
    }
}

// MARK: - UI

final class BubbleCell: UITableViewCell {
    static let reuseID = "BubbleCell"

    private let bubble = UIView()
    private let nameLabel = UILabel()
    private let messageLabel = UILabel()
    private let timeLabel = UILabel()
    private let receiptLabel = UILabel()
    private let reactionLabel = UILabel()

    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        bubble.layer.cornerRadius = 18
        bubble.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.textColor = .secondaryLabel

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.numberOfLines = 0

        timeLabel.font = .preferredFont(forTextStyle: .caption2)
        timeLabel.textColor = .secondaryLabel

        receiptLabel.font = .preferredFont(forTextStyle: .caption2)
        receiptLabel.textColor = .secondaryLabel

        reactionLabel.font = .systemFont(ofSize: 19)

        let metaStack = UIStackView(arrangedSubviews: [timeLabel, receiptLabel])
        metaStack.axis = .horizontal
        metaStack.spacing = 8

        let stack = UIStackView(arrangedSubviews: [nameLabel, messageLabel, metaStack, reactionLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        bubble.addSubview(stack)
        contentView.addSubview(bubble)

        leading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),

            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            leading,
            trailing,
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(message: ChatMessage, formatter: DateFormatter) {
        nameLabel.text = message.senderName
        messageLabel.text = message.text
        timeLabel.text = formatter.string(from: message.timestamp)
        receiptLabel.text = message.isMe ? message.receipt.rawValue.capitalized : ""
        reactionLabel.text = message.reactions.values.joined(separator: " ")

        if message.isMe {
            bubble.backgroundColor = .systemBlue
            messageLabel.textColor = .white
            nameLabel.textColor = UIColor.white.withAlphaComponent(0.85)
            timeLabel.textColor = UIColor.white.withAlphaComponent(0.7)
            receiptLabel.textColor = UIColor.white.withAlphaComponent(0.7)
            leading.isActive = false
            trailing.isActive = true
        } else {
            bubble.backgroundColor = .secondarySystemBackground
            messageLabel.textColor = .label
            nameLabel.textColor = .secondaryLabel
            timeLabel.textColor = .secondaryLabel
            receiptLabel.textColor = .secondaryLabel
            trailing.isActive = false
            leading.isActive = true
        }
    }
}

final class ChatViewController: UIViewController {
    private let myID = UUID().uuidString
    private let myName: String
    private let conversationID = UUID(uuidString: "56B24C55-35AA-4412-B48B-D7689E5A9486")!

    private lazy var peerService = PeerService(displayName: myName)

    private var messages: [ChatMessage] = []
    private var typingPeers = Set<String>()

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let inputContainer = UIView()
    private let textView = UITextView()
    private let sendButton = UIButton(type: .system)
    private let typingLabel = UILabel()
    private let peersLabel = UILabel()

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    init(displayName: String) {
        self.myName = displayName
        super.init(nibName: nil, bundle: nil)
        title = "Messages"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        peerService.delegate = self
        peerService.start()

        setupTable()
        setupInput()
        setupHeader()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTableTap))
        tableView.addGestureRecognizer(tap)
    }

    private func setupHeader() {
        peersLabel.font = .preferredFont(forTextStyle: .footnote)
        peersLabel.textColor = .secondaryLabel
        peersLabel.text = "Searching for peers..."
        peersLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(peersLabel)
        NSLayoutConstraint.activate([
            peersLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            peersLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(BubbleCell.self, forCellReuseIdentifier: BubbleCell.reuseID)
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.dataSource = self

        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: peersLabel.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupInput() {
        inputContainer.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.backgroundColor = .tertiarySystemBackground
        inputContainer.layer.cornerRadius = 16

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.layer.cornerRadius = 12

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        typingLabel.translatesAutoresizingMaskIntoConstraints = false
        typingLabel.font = .preferredFont(forTextStyle: .caption1)
        typingLabel.textColor = .secondaryLabel

        view.addSubview(inputContainer)
        inputContainer.addSubview(textView)
        inputContainer.addSubview(sendButton)
        view.addSubview(typingLabel)

        NSLayoutConstraint.activate([
            inputContainer.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 8),
            inputContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            inputContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            inputContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),

            textView.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 10),
            textView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -8),

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 58),

            typingLabel.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 4),
            typingLabel.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -4)
        ])
    }

    @objc private func sendTapped() {
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var message = ChatMessage(
            id: UUID(),
            senderID: myID,
            senderName: myName,
            text: trimmed,
            timestamp: Date(),
            receipt: .sent,
            reactions: [:],
            isMe: true
        )

        messages.append(message)
        textView.text = ""
        insertLastRow()

        let payload = ChatPayload(
            id: message.id,
            conversationID: conversationID,
            senderID: myID,
            senderName: myName,
            type: .text,
            text: trimmed
        )
        peerService.send(payload)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let idx = self.messages.firstIndex(where: { $0.id == message.id }) {
                message.receipt = .delivered
                self.messages[idx] = message
                self.tableView.reloadRows(at: [IndexPath(row: idx, section: 0)], with: .none)
            }
        }
    }

    private func insertLastRow() {
        let idx = IndexPath(row: messages.count - 1, section: 0)
        tableView.insertRows(at: [idx], with: .automatic)
        tableView.scrollToRow(at: idx, at: .bottom, animated: true)
    }

    private func updateTypingLabel() {
        if typingPeers.isEmpty {
            typingLabel.text = ""
        } else {
            typingLabel.text = "\(typingPeers.joined(separator: ", ")) typing…"
        }
    }

    private func sendTyping(_ isTyping: Bool) {
        let payload = ChatPayload(
            conversationID: conversationID,
            senderID: myID,
            senderName: myName,
            type: .typing,
            text: isTyping ? "1" : "0"
        )
        peerService.send(payload)
    }

    @objc private func handleTableTap(_ sender: UITapGestureRecognizer) {
        let location = sender.location(in: tableView)
        guard let idx = tableView.indexPathForRow(at: location) else { return }
        guard !messages[idx.row].isMe else { return }

        let reaction = ["👍", "❤️", "😂", "‼️"].randomElement()!
        messages[idx.row].reactions[myID] = reaction
        tableView.reloadRows(at: [idx], with: .none)

        let payload = ChatPayload(
            conversationID: conversationID,
            senderID: myID,
            senderName: myName,
            type: .reaction,
            targetMessageID: messages[idx.row].id,
            reaction: reaction
        )
        peerService.send(payload)
    }
}

extension ChatViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: BubbleCell.reuseID, for: indexPath) as? BubbleCell else {
            return UITableViewCell()
        }
        cell.configure(message: messages[indexPath.row], formatter: formatter)
        return cell
    }
}

extension ChatViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        sendTyping(!textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

extension ChatViewController: PeerServiceDelegate {
    func peerService(_ service: PeerService, peersDidChange peers: [MCPeerID]) {
        peersLabel.text = peers.isEmpty ? "No peers connected" : "Connected: \(peers.map(\.displayName).joined(separator: ", "))"
    }

    func peerService(_ service: PeerService, didReceive payload: ChatPayload) {
        guard payload.conversationID == conversationID else { return }

        switch payload.type {
        case .text:
            guard let text = payload.text else { return }
            let message = ChatMessage(
                id: payload.id,
                senderID: payload.senderID,
                senderName: payload.senderName,
                text: text,
                timestamp: payload.timestamp,
                receipt: .delivered,
                reactions: [:],
                isMe: false
            )
            messages.append(message)
            insertLastRow()

            let receiptPayload = ChatPayload(
                conversationID: conversationID,
                senderID: myID,
                senderName: myName,
                type: .receipt,
                targetMessageID: payload.id,
                receiptState: .read
            )
            peerService.send(receiptPayload)

        case .typing:
            if payload.text == "1" {
                typingPeers.insert(payload.senderName)
            } else {
                typingPeers.remove(payload.senderName)
            }
            updateTypingLabel()

        case .receipt:
            guard let id = payload.targetMessageID, let state = payload.receiptState,
                  let idx = messages.firstIndex(where: { $0.id == id && $0.isMe }) else { return }
            messages[idx].receipt = state
            tableView.reloadRows(at: [IndexPath(row: idx, section: 0)], with: .none)

        case .reaction:
            guard let id = payload.targetMessageID,
                  let reaction = payload.reaction,
                  let idx = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[idx].reactions[payload.senderID] = reaction
            tableView.reloadRows(at: [IndexPath(row: idx, section: 0)], with: .none)
        }
    }
}

// MARK: - Bootstrap

let randomName = ["Alex", "Jordan", "Taylor", "Quinn", "Riley", "Sam"].randomElement()!
let vc = UINavigationController(rootViewController: ChatViewController(displayName: randomName))
vc.view.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
PlaygroundPage.current.liveView = vc
PlaygroundPage.current.needsIndefiniteExecution = true
