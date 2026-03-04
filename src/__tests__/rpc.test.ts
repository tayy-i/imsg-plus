import { describe, it, expect } from "vitest"
import { need, str, int, bool, InvalidParams } from "../rpc.js"

describe("need", () => {
  it("returns value when present", () => {
    expect(need(42, "x")).toBe(42)
    expect(need("hello", "x")).toBe("hello")
  })

  it("throws InvalidParams for null", () => {
    expect(() => need(null, "chat_id")).toThrow(InvalidParams)
    expect(() => need(null, "chat_id")).toThrow("chat_id is required")
  })

  it("throws InvalidParams for undefined", () => {
    expect(() => need(undefined, "handle")).toThrow(InvalidParams)
  })
})

describe("str", () => {
  it("returns string values", () => {
    expect(str("hello")).toBe("hello")
    expect(str("")).toBe("")
  })

  it("converts numbers to strings", () => {
    expect(str(42)).toBe("42")
    expect(str(0)).toBe("0")
  })

  it("returns null for non-string, non-number", () => {
    expect(str(null)).toBeNull()
    expect(str(undefined)).toBeNull()
    expect(str(true)).toBeNull()
    expect(str({})).toBeNull()
    expect(str([])).toBeNull()
  })
})

describe("int", () => {
  it("floors numbers", () => {
    expect(int(42)).toBe(42)
    expect(int(3.7)).toBe(3)
    expect(int(-1.5)).toBe(-2)
  })

  it("parses string integers", () => {
    expect(int("42")).toBe(42)
    expect(int("0")).toBe(0)
    expect(int("-5")).toBe(-5)
  })

  it("returns null for non-numeric strings", () => {
    expect(int("abc")).toBeNull()
    expect(int("")).toBeNull()
  })

  it("returns null for non-number, non-string", () => {
    expect(int(null)).toBeNull()
    expect(int(undefined)).toBeNull()
    expect(int(true)).toBeNull()
    expect(int({})).toBeNull()
  })
})

describe("bool", () => {
  it("returns boolean values directly", () => {
    expect(bool(true)).toBe(true)
    expect(bool(false)).toBe(false)
  })

  it("parses string booleans", () => {
    expect(bool("true")).toBe(true)
    expect(bool("false")).toBe(false)
  })

  it("returns null for non-boolean", () => {
    expect(bool(null)).toBeNull()
    expect(bool(undefined)).toBeNull()
    expect(bool(0)).toBeNull()
    expect(bool(1)).toBeNull()
    expect(bool("yes")).toBeNull()
    expect(bool("")).toBeNull()
  })
})
