/**
 * ARCHIVE_PERIOD: how long telemetry is kept on the deployment, for example
 * "365d", "12w", "48h" or a number of milliseconds. Unset or empty means data is
 * never deleted. An invalid value also deletes nothing (and is logged), so a typo
 * can never wipe data.
 */
const units: Record<string, number> = {
  ms: 1, s: 1_000, m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000,
};

export function parseArchivePeriod(value: string | undefined): number | null {
  const text = value?.trim();
  if (!text) return null;
  const match = /^(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)?$/i.exec(text);
  if (!match) return null;
  const ms = Number(match[1]) * units[(match[2] ?? "ms").toLowerCase()];
  return Number.isFinite(ms) && ms > 0 ? ms : null;
}

export function archivePeriodMs(): number | null {
  const raw = process.env.ARCHIVE_PERIOD;
  const ms = parseArchivePeriod(raw);
  if (raw?.trim() && ms === null) console.error(`Ignoring invalid ARCHIVE_PERIOD "${raw}"`);
  return ms;
}
