// Minimal DTL1 encoder for tests, following docs/BINARY_FORMAT.md and
// backend_reference/telemetry_decoder.ts.
import { gzip } from "pako";

class Writer {
  bytes: number[] = [];
  uint(value: number) {
    let rest = Math.round(value);
    while (rest >= 0x80) { this.bytes.push((rest % 0x80) | 0x80); rest = Math.floor(rest / 0x80); }
    this.bytes.push(rest);
  }
  int(value: number) { const v = Math.round(value); this.uint(v >= 0 ? v * 2 : -v * 2 - 1); }
  string(value: string) { const b = new TextEncoder().encode(value); this.uint(b.length); this.bytes.push(...b); }
  byte(value: number) { this.bytes.push(value); }
}

export type Fix = { t: number; latitude: number; longitude: number; speedMps: number };
export type Frame = { t: number; vertical: number };
export type Event = { id: string; t: number; type: number };

const axis = (w: Writer, value: number) => {
  w.int(value * 1000); w.int(value * 1000); w.int(value * 1000); w.uint(0); w.uint(Math.abs(value) * 1000); w.uint(25);
};

export function continuousChunk(args: {
  tripId: string; chunkId: string; chunkIndex: number; startedAt: number; endedAt: number;
  fixes: Fix[]; frames?: Frame[]; events?: Event[];
}) {
  const w = new Writer();
  w.bytes.push(...new TextEncoder().encode("DTL1"));
  w.uint(1); w.uint(0); // schema version, chunk type continuous
  w.string(args.tripId); w.string(args.chunkId); w.uint(args.chunkIndex);
  w.uint(args.startedAt); w.uint(args.endedAt - args.startedAt);
  w.uint(args.fixes.length);
  let time = args.startedAt, lat = 0, lng = 0;
  for (const fix of args.fixes) {
    const latE7 = Math.round(fix.latitude * 1e7), lngE7 = Math.round(fix.longitude * 1e7);
    w.uint(fix.t - time); w.int(latE7 - lat); w.int(lngE7 - lng);
    w.uint(fix.speedMps * 100); w.uint(9000); w.uint(50); w.int(120); w.uint(30); w.uint(500); w.byte(0);
    time = fix.t; lat = latE7; lng = lngE7;
  }
  const frames = args.frames ?? [];
  w.uint(frames.length);
  for (const frame of frames) {
    w.uint(frame.t - args.startedAt); w.uint(1000);
    axis(w, 0.1); axis(w, 0.2); axis(w, frame.vertical); axis(w, 0.01); axis(w, 0.02); axis(w, 0.03);
    w.uint(900); w.byte(1);
  }
  w.uint(0); // raw motion samples
  const events = args.events ?? [];
  w.uint(events.length);
  for (const event of events) {
    w.string(event.id); w.uint(event.type); w.uint(event.t - args.startedAt); w.uint(800);
    w.uint(700); w.int(-3000); w.int(-1000); w.int(-2000); w.uint(0);
  }
  w.byte(0); // no hourly aggregate
  const body = gzip(new Uint8Array(w.bytes));
  return body;
}

export async function sha256Hex(bytes: Uint8Array) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, b => b.toString(16).padStart(2, "0")).join("");
}
