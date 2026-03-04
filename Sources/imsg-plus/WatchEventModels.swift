import Foundation
import IMsgCore

enum WatchEventType: String, Codable {
  case message
  case typing
  case read
  case delivered
  case reaction
}

protocol WatchEvent: Codable {
  var type: WatchEventType { get }
  var timestamp: String { get }
}

struct MessageEvent: WatchEvent {
  let type = WatchEventType.message
  let timestamp: String
  let id: Int64
  let chatID: Int64
  let guid: String
  let replyToGUID: String?
  let sender: String
  let senderName: String?
  let isFromMe: Bool
  let text: String
  let markdownText: String?
  let attachments: [AttachmentPayload]
  let reactions: [ReactionPayload]

  init(
    message: Message,
    attachments: [AttachmentMeta],
    reactions: [Reaction],
    senderName: String? = nil,
    markdownText: String? = nil
  ) {
    self.timestamp = CLIISO8601.format(Date())
    self.id = message.rowID
    self.chatID = message.chatID
    self.guid = message.guid
    self.replyToGUID = message.replyToGUID
    self.sender = message.sender
    self.senderName = senderName
    self.isFromMe = message.isFromMe
    self.text = message.text
    self.markdownText = markdownText
    self.attachments = attachments.map { AttachmentPayload(meta: $0) }
    self.reactions = reactions.map { ReactionPayload(reaction: $0) }
  }

  enum CodingKeys: String, CodingKey {
    case type
    case timestamp
    case id
    case chatID = "chat_id"
    case guid
    case replyToGUID = "reply_to_guid"
    case sender
    case senderName = "sender_name"
    case isFromMe = "is_from_me"
    case text
    case markdownText = "markdown_text"
    case attachments
    case reactions
  }
}

struct TypingEvent: WatchEvent {
  let type = WatchEventType.typing
  let timestamp: String
  let sender: String
  let chatID: String
  let started: Bool

  init(sender: String, chatID: String, started: Bool) {
    self.timestamp = CLIISO8601.format(Date())
    self.sender = sender
    self.chatID = chatID
    self.started = started
  }

  enum CodingKeys: String, CodingKey {
    case type
    case timestamp
    case sender
    case chatID = "chat_id"
    case started
  }
}

struct ReadEvent: WatchEvent {
  let type = WatchEventType.read
  let timestamp: String
  let by: String
  let messageGUID: String
  let chatID: String

  init(by: String, messageGUID: String, chatID: String) {
    self.timestamp = CLIISO8601.format(Date())
    self.by = by
    self.messageGUID = messageGUID
    self.chatID = chatID
  }

  enum CodingKeys: String, CodingKey {
    case type
    case timestamp
    case by
    case messageGUID = "message_guid"
    case chatID = "chat_id"
  }
}

struct DeliveredEvent: WatchEvent {
  let type = WatchEventType.delivered
  let timestamp: String
  let messageGUID: String
  let to: String

  init(messageGUID: String, to: String) {
    self.timestamp = CLIISO8601.format(Date())
    self.messageGUID = messageGUID
    self.to = to
  }

  enum CodingKeys: String, CodingKey {
    case type
    case timestamp
    case messageGUID = "message_guid"
    case to
  }
}

struct ReactionEvent: WatchEvent {
  let type = WatchEventType.reaction
  let timestamp: String
  let sender: String
  let messageGUID: String
  let reaction: String
  let emoji: String
  let added: Bool

  init(sender: String, messageGUID: String, reaction: String, emoji: String, added: Bool) {
    self.timestamp = CLIISO8601.format(Date())
    self.sender = sender
    self.messageGUID = messageGUID
    self.reaction = reaction
    self.emoji = emoji
    self.added = added
  }

  enum CodingKeys: String, CodingKey {
    case type
    case timestamp
    case sender
    case messageGUID = "message_guid"
    case reaction
    case emoji
    case added
  }
}
