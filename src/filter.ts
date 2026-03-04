import type { Filter } from "./types.js"

/**
 * Parse filter options from either CLI args or RPC params.
 * Returns undefined when no filters are specified.
 */
export function parseFilter(opts: {
  participants?: string | string[]
  start?: string
  end?: string
}): Filter | undefined {
  const participants = normalizeParticipants(opts.participants)
  const after = opts.start ? new Date(opts.start) : undefined
  const before = opts.end ? new Date(opts.end) : undefined
  if (!participants?.length && !after && !before) return undefined
  return { participants, after, before }
}

function normalizeParticipants(v: string | string[] | undefined): string[] | undefined {
  if (!v) return undefined
  const list = Array.isArray(v)
    ? v.filter((x): x is string => typeof x === "string")
    : v.split(",").map((s) => s.trim()).filter(Boolean)
  return list.length ? list : undefined
}
