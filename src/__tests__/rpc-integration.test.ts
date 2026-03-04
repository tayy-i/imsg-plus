import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { PassThrough } from "node:stream"
import type { Chat, Message } from "../types.js"

// Mock node:fs to prevent real fs.watch in watch.ts
vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs")>()
  return {
    ...actual,
    watch: () => ({ close: vi.fn() }),
  }
})

const { serve } = await import("../rpc.js")

function makeChat(id: number): Chat {
  return {
    id,
    guid: `iMessage;-;chat${id}`,
    identifier: `+1555000${id}`,
    name: `Chat ${id}`,
    service: "iMessage",
    isGroup: false,
    lastMessageAt: new Date("2024-06-01"),
  }
}

function makeMessage(id: number, chatId: number): Message {
  return {
    id,
    chatId,
    guid: `msg-${id}`,
    replyToGuid: null,
    sender: "+15550001",
    text: `Message ${id}`,
    date: new Date("2024-06-01"),
    isFromMe: false,
    service: "iMessage",
    attachments: 0,
  }
}

interface TestHarness {
  stdin: PassThrough
  stdout: PassThrough
  serverDone: Promise<void>
  sendRequest: (obj: unknown) => void
  readResponse: () => Promise<any>
  readAllResponses: (count: number) => Promise<any[]>
}

function createHarness(dbOverrides: Record<string, any> = {}, bridgeOverrides: Record<string, any> = {}): TestHarness {
  const stdin = new PassThrough()
  const stdout = new PassThrough()

  const mockDb = {
    path: "/tmp/fake.db",
    maxRowId: () => 100,
    chats: (limit: number) => [makeChat(1), makeChat(2)].slice(0, limit),
    chat: (id: number) => (id === 1 ? makeChat(1) : null),
    participants: () => ["+15550001", "+15550002"],
    messages: (chatId: number) => [makeMessage(1, chatId), makeMessage(2, chatId)],
    messagesAfter: () => [],
    attachments: () => [],
    ...dbOverrides,
  }

  const mockBridge = {
    available: false,
    dylibPath: null,
    setTyping: vi.fn().mockResolvedValue(undefined),
    markRead: vi.fn().mockResolvedValue(undefined),
    launch: vi.fn().mockResolvedValue(undefined),
    kill: vi.fn(),
    ...bridgeOverrides,
  }

  // Swap stdin/stdout
  const origStdin = process.stdin
  const origStdout = process.stdout
  Object.defineProperty(process, "stdin", { value: stdin, writable: true, configurable: true })
  Object.defineProperty(process, "stdout", { value: stdout, writable: true, configurable: true })

  const serverDone = serve(mockDb as any, mockBridge).finally(() => {
    Object.defineProperty(process, "stdin", { value: origStdin, writable: true, configurable: true })
    Object.defineProperty(process, "stdout", { value: origStdout, writable: true, configurable: true })
  })

  function sendRequest(obj: unknown) {
    stdin.write(JSON.stringify(obj) + "\n")
  }

  function readResponse(): Promise<any> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Timeout waiting for response")), 3000)

      function onData(chunk: Buffer) {
        const lines = chunk.toString().split("\n").filter(Boolean)
        for (const line of lines) {
          try {
            clearTimeout(timeout)
            stdout.removeListener("data", onData)
            resolve(JSON.parse(line))
            return
          } catch {}
        }
      }

      stdout.on("data", onData)
    })
  }

  async function readAllResponses(count: number): Promise<any[]> {
    const results: any[] = []
    for (let i = 0; i < count; i++) {
      results.push(await readResponse())
    }
    return results
  }

  return { stdin, stdout, serverDone, sendRequest, readResponse, readAllResponses }
}

describe("RPC integration", () => {
  it("chats.list returns correct shape", async () => {
    const h = createHarness()
    h.sendRequest({ jsonrpc: "2.0", id: 1, method: "chats.list", params: { limit: 2 } })
    const res = await h.readResponse()

    expect(res.jsonrpc).toBe("2.0")
    expect(res.id).toBe(1)
    expect(res.result.chats).toHaveLength(2)
    expect(res.result.chats[0]).toHaveProperty("id")
    expect(res.result.chats[0]).toHaveProperty("identifier")
    expect(res.result.chats[0]).toHaveProperty("participants")
    expect(res.result.chats[0]).toHaveProperty("is_group")

    h.stdin.end()
    await h.serverDone
  })

  it("messages.history with filter passes through", async () => {
    let receivedOpts: any
    const h = createHarness({
      messages: (_chatId: number, opts: any) => {
        receivedOpts = opts
        return [makeMessage(1, 1)]
      },
    })

    h.sendRequest({
      jsonrpc: "2.0",
      id: 2,
      method: "messages.history",
      params: { chat_id: 1, limit: 10, participants: "alice" },
    })

    const res = await h.readResponse()
    expect(res.id).toBe(2)
    expect(res.result.messages).toHaveLength(1)
    expect(receivedOpts.filter).toBeDefined()

    h.stdin.end()
    await h.serverDone
  })

  it("subscribe → message → unsubscribe lifecycle", async () => {
    let callCount = 0
    const h = createHarness({
      messagesAfter: () => {
        callCount++
        if (callCount === 1) return [makeMessage(101, 1)]
        return []
      },
    })

    // Subscribe
    h.sendRequest({ jsonrpc: "2.0", id: 3, method: "watch.subscribe", params: {} })
    const subRes = await h.readResponse()
    expect(subRes.result.subscription).toBe(1)

    // Wait for the notification
    const notification = await h.readResponse()
    expect(notification.method).toBe("message")
    expect(notification.params.subscription).toBe(1)
    expect(notification.params.message).toHaveProperty("text")

    // Unsubscribe
    h.sendRequest({ jsonrpc: "2.0", id: 4, method: "watch.unsubscribe", params: { subscription: 1 } })
    const unsubRes = await h.readResponse()
    expect(unsubRes.result.ok).toBe(true)

    h.stdin.end()
    await h.serverDone
  })

  it("stdin close aborts all subscriptions", async () => {
    const h = createHarness()

    // Create 2 subscriptions
    h.sendRequest({ jsonrpc: "2.0", id: 5, method: "watch.subscribe", params: {} })
    h.sendRequest({ jsonrpc: "2.0", id: 6, method: "watch.subscribe", params: {} })

    const [res1, res2] = await h.readAllResponses(2)
    expect(res1.result.subscription).toBe(1)
    expect(res2.result.subscription).toBe(2)

    // Close stdin — should abort both subscriptions
    h.stdin.end()
    await h.serverDone
    // If we get here without hanging, subscriptions were properly cleaned up
  })

  it("malformed JSON returns parse error (-32700)", async () => {
    const h = createHarness()
    h.stdin.write("this is not json\n")
    const res = await h.readResponse()

    expect(res.error.code).toBe(-32700)
    expect(res.error.message).toBe("Parse error")

    h.stdin.end()
    await h.serverDone
  })

  it("unknown method returns -32601", async () => {
    const h = createHarness()
    h.sendRequest({ jsonrpc: "2.0", id: 7, method: "fake.method", params: {} })
    const res = await h.readResponse()

    expect(res.id).toBe(7)
    expect(res.error.code).toBe(-32601)
    expect(res.error.message).toBe("Method not found")

    h.stdin.end()
    await h.serverDone
  })

  it("InvalidParams propagates correctly (-32602)", async () => {
    const h = createHarness()
    // messages.history requires chat_id
    h.sendRequest({ jsonrpc: "2.0", id: 8, method: "messages.history", params: {} })
    const res = await h.readResponse()

    expect(res.id).toBe(8)
    expect(res.error.code).toBe(-32602)
    expect(res.error.message).toBe("Invalid params")
    expect(res.error.data).toContain("chat_id")

    h.stdin.end()
    await h.serverDone
  })
})
