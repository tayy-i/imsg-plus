import { describe, it, expect } from "vitest"
import Database from "better-sqlite3"
import { nanosToDate, dateToNanos, parseAttributedBody, extractReplyGuid, open } from "../db.js"

const APPLE_EPOCH = 978307200

describe("nanosToDate / dateToNanos", () => {
  it("round-trips a known date", () => {
    const date = new Date("2024-06-15T12:00:00.000Z")
    const nanos = dateToNanos(date)
    const back = nanosToDate(nanos)
    expect(back.toISOString()).toBe(date.toISOString())
  })

  it("returns Apple epoch for null/zero nanos", () => {
    expect(nanosToDate(null).getTime()).toBe(APPLE_EPOCH * 1000)
    expect(nanosToDate(0).getTime()).toBe(APPLE_EPOCH * 1000)
  })

  it("handles recent dates correctly", () => {
    const date = new Date("2025-01-01T00:00:00.000Z")
    const nanos = dateToNanos(date)
    expect(nanos).toBeGreaterThan(0)
    expect(nanosToDate(nanos).toISOString()).toBe("2025-01-01T00:00:00.000Z")
  })
})

describe("parseAttributedBody", () => {
  it("returns empty string for null/empty", () => {
    expect(parseAttributedBody(null)).toBe("")
    expect(parseAttributedBody(Buffer.alloc(0))).toBe("")
  })

  it("extracts text between TypedStream markers", () => {
    // Build a buffer with 0x01 0x2b ... text ... 0x86 0x84
    const text = "Hello, world!"
    const marker = Buffer.from([0x01, 0x2b])
    const terminator = Buffer.from([0x86, 0x84])
    const textBuf = Buffer.from(text, "utf8")
    const blob = Buffer.concat([marker, textBuf, terminator])
    expect(parseAttributedBody(blob)).toBe(text)
  })

  it("picks the longest segment when multiple exist", () => {
    const marker = Buffer.from([0x01, 0x2b])
    const terminator = Buffer.from([0x86, 0x84])
    const short = Buffer.from("Hi", "utf8")
    const long = Buffer.from("This is the longer text", "utf8")
    const blob = Buffer.concat([marker, short, terminator, Buffer.from([0x00]), marker, long, terminator])
    expect(parseAttributedBody(blob)).toBe("This is the longer text")
  })

  it("falls back to full buffer toString when no markers found", () => {
    const blob = Buffer.from("plain text content")
    expect(parseAttributedBody(blob)).toBe("plain text content")
  })

  it("handles length-prefixed segments", () => {
    const marker = Buffer.from([0x01, 0x2b])
    const terminator = Buffer.from([0x86, 0x84])
    const text = "Test"
    const textBuf = Buffer.from(text, "utf8")
    // Length prefix: first byte = length of remaining segment
    const prefixed = Buffer.concat([Buffer.from([textBuf.length]), textBuf])
    const blob = Buffer.concat([marker, prefixed, terminator])
    expect(parseAttributedBody(blob)).toBe("Test")
  })
})

describe("extractReplyGuid", () => {
  it("returns null for null guid", () => {
    expect(extractReplyGuid(null, null)).toBeNull()
  })

  it("extracts guid after last slash", () => {
    expect(extractReplyGuid("p:0/ABCD-1234", null)).toBe("ABCD-1234")
  })

  it("returns guid as-is when no slash", () => {
    expect(extractReplyGuid("ABCD-1234", null)).toBe("ABCD-1234")
  })

  it("returns null for reaction types (2000-3006)", () => {
    expect(extractReplyGuid("p:0/ABCD-1234", 2000)).toBeNull()
    expect(extractReplyGuid("p:0/ABCD-1234", 2500)).toBeNull()
    expect(extractReplyGuid("p:0/ABCD-1234", 3006)).toBeNull()
  })

  it("returns guid for types outside reaction range", () => {
    expect(extractReplyGuid("p:0/ABCD-1234", 1999)).toBe("ABCD-1234")
    expect(extractReplyGuid("p:0/ABCD-1234", 3007)).toBe("ABCD-1234")
  })

  it("returns full guid when slash is at end", () => {
    // When slash is the last char, there's nothing after it to extract,
    // so the code returns the full guid (slash >= guid.length - 1)
    expect(extractReplyGuid("p:0/", null)).toBe("p:0/")
  })
})

describe("open (file-based)", () => {
  const { unlinkSync } = require("node:fs")
  const { join } = require("node:path")
  const { tmpdir } = require("node:os")

  function createTestDB(): string {
    const tmpPath = join(tmpdir(), `imsg-test-${Date.now()}.db`)
    const db = new Database(tmpPath)
    db.exec(`
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT
      );
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        attributedBody BLOB,
        destination_caller_id TEXT,
        is_audio_message INTEGER
      );
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT,
        transfer_name TEXT,
        uti TEXT,
        mime_type TEXT,
        total_bytes INTEGER,
        is_sticker INTEGER,
        user_info BLOB
      );
    `)
    db.exec(`
      INSERT INTO handle VALUES (1, '+15551234567');
      INSERT INTO chat VALUES (1, '+15551234567', 'iMessage;-;+15551234567', 'Alice', 'iMessage');
      INSERT INTO chat VALUES (2, 'chat123;+;group', 'iMessage;+;chat123', 'Group Chat', 'iMessage');
      INSERT INTO message VALUES (1, 1, 'Hello', 700000000000000000, 0, 'iMessage', 'guid-1', NULL, NULL, NULL, NULL, 0);
      INSERT INTO message VALUES (2, 1, 'Hey group', 700000000000000001, 0, 'iMessage', 'guid-2', NULL, NULL, NULL, NULL, 0);
      INSERT INTO chat_message_join VALUES (1, 1);
      INSERT INTO chat_message_join VALUES (2, 2);
    `)
    db.close()
    return tmpPath
  }

  it("queries chats with isGroup computed", () => {
    const tmpPath = createTestDB()
    const imsg = open(tmpPath)
    try {
      const chats = imsg.chats(10)
      expect(chats.length).toBe(2)

      const directChat = chats.find((c) => c.id === 1)!
      expect(directChat.isGroup).toBe(false)

      const groupChat = chats.find((c) => c.id === 2)!
      expect(groupChat.isGroup).toBe(true)
      expect(groupChat.guid).toBeTruthy()
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })
})
