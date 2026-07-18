export type DecodedAxisStatistics = {
  minimum: number
  maximum: number
  mean: number
  standardDeviation: number
  rms: number
  sampleCount: number
}

export type DecodedTelemetryChunk = {
  schemaVersion: number
  chunkType: number
  tripId: string
  chunkId: string
  chunkIndex: number
  startedAtMillis: number
  endedAtMillis: number
  locations: Array<Record<string, number | boolean>>
  motionFrames: Array<Record<string, unknown>>
  rawMotionSamples: Array<Record<string, unknown>>
  events: Array<Record<string, unknown>>
  hourlyAggregate: Record<string, unknown> | null
}

class CompactReader {
  private offset = 0
  private readonly decoder = new TextDecoder()

  constructor(private readonly bytes: Uint8Array) {}

  readByte(): number {
    if (this.offset >= this.bytes.length) {
      throw new Error('Unexpected end of telemetry payload')
    }
    return this.bytes[this.offset++]
  }

  readBytes(length: number): Uint8Array {
    if (length < 0 || this.offset + length > this.bytes.length) {
      throw new Error('Invalid telemetry byte length')
    }
    const value = this.bytes.subarray(this.offset, this.offset + length)
    this.offset += length
    return value
  }

  readVarUint(): number {
    let result = 0
    let shift = 0
    while (true) {
      if (shift > 49) throw new Error('Telemetry varint exceeds safe integer range')
      const byte = this.readByte()
      result += (byte & 0x7f) * 2 ** shift
      if ((byte & 0x80) === 0) return result
      shift += 7
    }
  }

  readVarInt(): number {
    const zigzag = this.readVarUint()
    return zigzag % 2 === 0 ? zigzag / 2 : -((zigzag + 1) / 2)
  }

  readString(): string {
    return this.decoder.decode(this.readBytes(this.readVarUint()))
  }
}

const motionScale = 1000

function readAxis(reader: CompactReader): DecodedAxisStatistics {
  return {
    minimum: reader.readVarInt() / motionScale,
    maximum: reader.readVarInt() / motionScale,
    mean: reader.readVarInt() / motionScale,
    standardDeviation: reader.readVarUint() / motionScale,
    rms: reader.readVarUint() / motionScale,
    sampleCount: reader.readVarUint(),
  }
}

function readVector(reader: CompactReader): { x: number; y: number; z: number } {
  return {
    x: reader.readVarInt() / motionScale,
    y: reader.readVarInt() / motionScale,
    z: reader.readVarInt() / motionScale,
  }
}

export function decodeTelemetryChunk(bytes: Uint8Array): DecodedTelemetryChunk {
  const reader = new CompactReader(bytes)
  const magic = Array.from(reader.readBytes(4))
  if (magic.join(',') !== '68,84,76,49') {
    throw new Error('Invalid DTL1 telemetry magic')
  }

  const schemaVersion = reader.readVarUint()
  if (schemaVersion !== 1) {
    throw new Error(`Unsupported telemetry schema version: ${schemaVersion}`)
  }

  const chunkType = reader.readVarUint()
  const tripId = reader.readString()
  const chunkId = reader.readString()
  const chunkIndex = reader.readVarUint()
  const startedAtMillis = reader.readVarUint()
  const endedAtMillis = startedAtMillis + reader.readVarUint()

  const locations: Array<Record<string, number | boolean>> = []
  let previousTime = startedAtMillis
  let previousLatitudeE7 = 0
  let previousLongitudeE7 = 0
  const locationCount = reader.readVarUint()
  for (let index = 0; index < locationCount; index++) {
    const timestampMillis = previousTime + reader.readVarUint()
    const latitudeE7 = previousLatitudeE7 + reader.readVarInt()
    const longitudeE7 = previousLongitudeE7 + reader.readVarInt()
    const location = {
      timestampMillis,
      latitude: latitudeE7 / 10_000_000,
      longitude: longitudeE7 / 10_000_000,
      speedMps: reader.readVarUint() / 100,
      headingDegrees: reader.readVarUint() / 100,
      accuracyMeters: reader.readVarUint() / 10,
      altitudeMeters: reader.readVarInt() / 10,
      speedAccuracyMps: reader.readVarUint() / 100,
      headingAccuracyDegrees: reader.readVarUint() / 100,
      isMocked: reader.readByte() === 1,
    }
    locations.push(location)
    previousTime = timestampMillis
    previousLatitudeE7 = latitudeE7
    previousLongitudeE7 = longitudeE7
  }

  const motionFrames: Array<Record<string, unknown>> = []
  const frameCount = reader.readVarUint()
  for (let index = 0; index < frameCount; index++) {
    motionFrames.push({
      startedAtMillis: startedAtMillis + reader.readVarUint(),
      durationMillis: reader.readVarUint(),
      longitudinalAcceleration: readAxis(reader),
      lateralAcceleration: readAxis(reader),
      verticalAcceleration: readAxis(reader),
      yawRate: readAxis(reader),
      pitchRate: readAxis(reader),
      rollRate: readAxis(reader),
      phoneStability: reader.readVarUint() / 1000,
      axisMappingCalibrated: reader.readByte() === 1,
    })
  }

  const rawMotionSamples: Array<Record<string, unknown>> = []
  let previousMicros = startedAtMillis * 1000
  const rawMotionCount = reader.readVarUint()
  for (let index = 0; index < rawMotionCount; index++) {
    const timestampMicros = previousMicros + reader.readVarUint()
    rawMotionSamples.push({
      timestampMicros,
      userAcceleration: readVector(reader),
      gyroscope: readVector(reader),
    })
    previousMicros = timestampMicros
  }

  const events: Array<Record<string, unknown>> = []
  const eventCount = reader.readVarUint()
  for (let index = 0; index < eventCount; index++) {
    const id = reader.readString()
    const eventType = reader.readVarUint()
    const eventStartedAtMillis = startedAtMillis + reader.readVarUint()
    const durationMillis = reader.readVarUint()
    const event: Record<string, unknown> = {
      id,
      eventType,
      startedAtMillis: eventStartedAtMillis,
      endedAtMillis: eventStartedAtMillis + durationMillis,
      confidence: reader.readVarUint() / 1000,
      minimumValue: reader.readVarInt() / motionScale,
      maximumValue: reader.readVarInt() / motionScale,
      meanValue: reader.readVarInt() / motionScale,
    }
    const flags = reader.readVarUint()
    if ((flags & 1) !== 0) event.speedBeforeMps = reader.readVarUint() / 100
    if ((flags & 2) !== 0) event.speedAfterMps = reader.readVarUint() / 100
    if ((flags & 4) !== 0) {
      event.latitude = reader.readVarInt() / 10_000_000
      event.longitude = reader.readVarInt() / 10_000_000
    }
    if ((flags & 8) !== 0) event.effectiveSpeedLimitKph = reader.readVarUint() / 100
    if ((flags & 16) !== 0) event.evidenceChunkId = reader.readString()
    if ((flags & 32) !== 0) event.metadata = JSON.parse(reader.readString())
    events.push(event)
  }

  let hourlyAggregate: Record<string, unknown> | null = null
  if (reader.readByte() === 1) {
    const hourStartedAtMillis = reader.readVarUint()
    const durationMillis = reader.readVarUint()
    const aggregate: Record<string, unknown> = {
      hourStartedAtMillis,
      hourEndedAtMillis: hourStartedAtMillis + durationMillis,
      distanceMeters: reader.readVarUint(),
      movingDurationMillis: reader.readVarUint(),
      speed: readAxis(reader),
      longitudinalAcceleration: readAxis(reader),
      lateralAcceleration: readAxis(reader),
      yawRate: readAxis(reader),
      locationSampleCount: reader.readVarUint(),
      validLocationSampleCount: reader.readVarUint(),
    }
    const aggregateEventCount = reader.readVarUint()
    const eventCounts: Record<string, number> = {}
    for (let index = 0; index < aggregateEventCount; index++) {
      eventCounts[String(reader.readVarUint())] = reader.readVarUint()
    }
    aggregate.eventCounts = eventCounts
    hourlyAggregate = aggregate
  }

  return {
    schemaVersion,
    chunkType,
    tripId,
    chunkId,
    chunkIndex,
    startedAtMillis,
    endedAtMillis,
    locations,
    motionFrames,
    rawMotionSamples,
    events,
    hourlyAggregate,
  }
}

export async function decodeCompressedTelemetry(
  compressedBytes: Uint8Array,
): Promise<DecodedTelemetryChunk> {
  const stream = new Blob([compressedBytes])
    .stream()
    .pipeThrough(new DecompressionStream('gzip'))
  const bytes = new Uint8Array(await new Response(stream).arrayBuffer())
  return decodeTelemetryChunk(bytes)
}
