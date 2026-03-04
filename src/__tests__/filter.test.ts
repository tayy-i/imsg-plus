import { describe, it, expect } from "vitest"
import { parseFilter } from "../filter.js"

describe("parseFilter", () => {
  it("returns undefined when no filters specified", () => {
    expect(parseFilter({})).toBeUndefined()
    expect(parseFilter({ participants: undefined })).toBeUndefined()
    expect(parseFilter({ participants: "" })).toBeUndefined()
    expect(parseFilter({ participants: [] })).toBeUndefined()
  })

  it("parses comma-separated participants string", () => {
    const result = parseFilter({ participants: "alice, bob, charlie" })
    expect(result).toEqual({
      participants: ["alice", "bob", "charlie"],
      after: undefined,
      before: undefined,
    })
  })

  it("parses participants array", () => {
    const result = parseFilter({ participants: ["alice", "bob"] })
    expect(result).toEqual({
      participants: ["alice", "bob"],
      after: undefined,
      before: undefined,
    })
  })

  it("filters out non-string values from array", () => {
    const result = parseFilter({ participants: ["alice", 123 as any, null as any, "bob"] })
    expect(result?.participants).toEqual(["alice", "bob"])
  })

  it("parses start date", () => {
    const result = parseFilter({ start: "2024-01-01" })
    expect(result?.after).toEqual(new Date("2024-01-01"))
    expect(result?.participants).toBeUndefined()
  })

  it("parses end date", () => {
    const result = parseFilter({ end: "2024-12-31" })
    expect(result?.before).toEqual(new Date("2024-12-31"))
  })

  it("parses all filters together", () => {
    const result = parseFilter({
      participants: "alice",
      start: "2024-01-01",
      end: "2024-12-31",
    })
    expect(result).toEqual({
      participants: ["alice"],
      after: new Date("2024-01-01"),
      before: new Date("2024-12-31"),
    })
  })

  it("trims whitespace from participant strings", () => {
    const result = parseFilter({ participants: "  alice  ,  bob  " })
    expect(result?.participants).toEqual(["alice", "bob"])
  })

  it("filters empty strings from split participants", () => {
    const result = parseFilter({ participants: "alice,,bob," })
    expect(result?.participants).toEqual(["alice", "bob"])
  })
})
