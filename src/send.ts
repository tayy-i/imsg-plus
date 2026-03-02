import { execFile } from "node:child_process"
import { copyFileSync, existsSync, mkdirSync } from "node:fs"
import { homedir } from "node:os"
import { basename, join, resolve } from "node:path"
import { randomUUID } from "node:crypto"
import { parsePhoneNumber } from "libphonenumber-js"
import type { DB } from "./db.js"

export interface SendOptions {
  to?: string
  chatId?: number
  chatIdentifier?: string
  chatGuid?: string
  text?: string
  file?: string
  service?: "imessage" | "sms" | "auto"
  region?: string
}

export async function send(opts: SendOptions, db?: DB): Promise<void> {
  if (!opts.text && !opts.file) throw new Error("--text or --file is required")

  const { recipient, chatTarget, service } = resolveTarget(opts, db)
  const attachment = opts.file ? stage(opts.file) : ""

  await osascript(SEND_SCRIPT, [
    recipient,
    (opts.text ?? "").trim(),
    service,
    attachment,
    attachment ? "1" : "0",
    chatTarget,
    chatTarget ? "1" : "0",
  ])
}

// Pure function: options in → exactly one of recipient/chatTarget out

function resolveTarget(opts: SendOptions, db?: DB) {
  const service = opts.service ?? "auto"
  const region = opts.region ?? "US"
  const directService = service === "auto" ? "imessage" : service
  const hasChat = opts.chatId != null || opts.chatIdentifier || opts.chatGuid

  if (opts.to && hasChat) throw new Error("Use --to or --chat-*, not both")
  if (!opts.to && !hasChat) throw new Error("--to or --chat-id is required")

  // Direct send to a phone/email
  if (opts.to) {
    return { recipient: normalize(opts.to, region), chatTarget: "", service: directService }
  }

  // Look up chat by numeric ID
  let identifier = opts.chatIdentifier ?? ""
  let guid = opts.chatGuid ?? ""
  if (opts.chatId != null) {
    const info = db?.chatInfo(opts.chatId)
    if (!info) throw new Error(`Unknown chat id ${opts.chatId}`)
    identifier = info.identifier
    guid = info.guid
  }

  // If the identifier is really just a phone/email, send directly
  if (identifier && looksLikeHandle(identifier)) {
    return { recipient: normalize(identifier, region), chatTarget: "", service: directService }
  }

  // Chat-based send (group chats, named chats)
  const target = guid || identifier
  if (!target) throw new Error("Missing chat identifier or guid")
  return { recipient: "", chatTarget: target, service }
}

function normalize(input: string, region: string): string {
  try {
    return parsePhoneNumber(input, region as any)?.format("E.164") ?? input
  } catch {
    return input
  }
}

function looksLikeHandle(value: string): boolean {
  if (value.includes("@")) return true
  return /^[+\d\s()\-]+$/.test(value)
}

function stage(filePath: string): string {
  const src = resolve(filePath.replace(/^~/, homedir()))
  if (!existsSync(src)) throw new Error(`Attachment not found: ${src}`)

  const dir = join(homedir(), "Library/Messages/Attachments/imsg", randomUUID())
  mkdirSync(dir, { recursive: true })
  const dest = join(dir, basename(src))
  copyFileSync(src, dest)
  return dest
}

function osascript(script: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = execFile("/usr/bin/osascript", ["-l", "AppleScript", "-", ...args])
    let stderr = ""
    child.stderr?.on("data", (d: Buffer) => (stderr += d))
    child.on("close", (code) => {
      if (code === 0) resolve()
      else reject(new Error(stderr.trim() || `osascript exited with code ${code}`))
    })
    child.stdin?.end(script)
  })
}

const SEND_SCRIPT = `
on run argv
    set theRecipient to item 1 of argv
    set theMessage to item 2 of argv
    set theService to item 3 of argv
    set theFilePath to item 4 of argv
    set useAttachment to item 5 of argv
    set chatId to item 6 of argv
    set useChat to item 7 of argv

    tell application "Messages"
        if useChat is "1" then
            set targetChat to chat id chatId
            if theMessage is not "" then
                send theMessage to targetChat
            end if
            if useAttachment is "1" then
                set theFile to POSIX file theFilePath as alias
                send theFile to targetChat
            end if
        else
            if theService is "sms" then
                set targetService to first service whose service type is SMS
            else
                set targetService to first service whose service type is iMessage
            end if
            set targetBuddy to buddy theRecipient of targetService
            if theMessage is not "" then
                send theMessage to targetBuddy
            end if
            if useAttachment is "1" then
                set theFile to POSIX file theFilePath as alias
                send theFile to targetBuddy
            end if
        end if
    end tell
end run
`.trim()
