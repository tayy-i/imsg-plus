import type { Message, Attachment } from "./types.js"

export function serializeMessage(msg: Message, attachments: Attachment[] = []) {
  return {
    id: msg.id,
    chat_id: msg.chatId,
    guid: msg.guid,
    reply_to_guid: msg.replyToGuid,
    sender: msg.sender,
    is_from_me: msg.isFromMe,
    text: msg.text,
    created_at: msg.date.toISOString(),
    attachments: attachments.map(serializeAttachment),
  }
}

export function serializeAttachment(a: Attachment) {
  return {
    filename: a.filename,
    transfer_name: a.transferName,
    uti: a.uti,
    mime_type: a.mimeType,
    total_bytes: a.totalBytes,
    is_sticker: a.isSticker,
    original_path: a.path,
    missing: a.missing,
  }
}
