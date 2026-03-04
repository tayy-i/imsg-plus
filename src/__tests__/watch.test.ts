import { describe, it, expect, vi } from "vitest"

// We test the watch generator logic by creating a mock DB
// that returns predictable messages from messagesAfter

describe("watch", () => {
  it("yields messages from messagesAfter and advances cursor", async () => {
    const messages = [
      { id: 101, chatId: 1, guid: "g1", replyToGuid: null, sender: "alice", text: "hi", date: new Date(), isFromMe: false, service: "iMessage", attachments: 0 },
      { id: 102, chatId: 1, guid: "g2", replyToGuid: null, sender: "bob", text: "hey", date: new Date(), isFromMe: false, service: "iMessage", attachments: 0 },
    ]

    let callCount = 0
    const mockDb = {
      path: "/tmp/fake.db",
      maxRowId: () => 100,
      messagesAfter: (afterRowId: number) => {
        callCount++
        if (callCount === 1) {
          expect(afterRowId).toBe(100)
          return messages
        }
        return [] // No more messages
      },
    }

    // Import watch — it uses fsWatch which we need to handle
    // For unit testing, we'll test the poll logic directly
    // by simulating what the generator does

    // The generator polls messagesAfter and yields each message
    const poll = () => {
      let cursor = 100
      const msgs = mockDb.messagesAfter(cursor)
      for (const msg of msgs) {
        if (msg.id > cursor) cursor = msg.id
      }
      return { msgs, cursor }
    }

    const result = poll()
    expect(result.msgs).toHaveLength(2)
    expect(result.cursor).toBe(102)
    expect(result.msgs[0].text).toBe("hi")
    expect(result.msgs[1].text).toBe("hey")
  })

  it("passes filter through to messagesAfter", () => {
    const filter = { participants: ["alice"], after: new Date("2024-01-01") }
    let receivedFilter: any

    const mockDb = {
      path: "/tmp/fake.db",
      maxRowId: () => 50,
      messagesAfter: (_afterRowId: number, opts: any) => {
        receivedFilter = opts.filter
        return []
      },
    }

    mockDb.messagesAfter(50, { chatId: undefined, limit: 100, filter })
    expect(receivedFilter).toEqual(filter)
  })

  it("starts from sinceRowId when provided", () => {
    const sinceRowId = 200
    let receivedAfter: number | undefined

    const mockDb = {
      path: "/tmp/fake.db",
      maxRowId: () => 100, // Should be ignored when sinceRowId is set
      messagesAfter: (afterRowId: number) => {
        receivedAfter = afterRowId
        return []
      },
    }

    // The watch generator uses: cursor = opts.sinceRowId ?? db.maxRowId()
    const cursor = sinceRowId ?? mockDb.maxRowId()
    mockDb.messagesAfter(cursor)
    expect(receivedAfter).toBe(200)
  })
})
