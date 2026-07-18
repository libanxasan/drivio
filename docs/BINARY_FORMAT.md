# DTL1 compact binary format

All integer fields use variable-length encoding. Signed integers use ZigZag encoding. Files are Gzip-compressed after encoding. The SHA-256 checksum in the manifest and upload headers is calculated from the compressed bytes.

## Header

| Field | Encoding |
|---|---|
| Magic | Four bytes: `44 54 4c 31` (`DTL1`) |
| Schema version | Varuint |
| Chunk type | Varuint enum index |
| Trip ID | Length-prefixed UTF-8 |
| Chunk ID | Length-prefixed UTF-8 |
| Chunk index | Varuint |
| Start time | Unix milliseconds, varuint |
| Duration | Milliseconds, varuint |

## Locations

The section begins with a record count. Timestamps, latitude, and longitude are deltas from the preceding record. The first timestamp is relative to the chunk start. The first coordinates are relative to zero.

| Field | Unit |
|---|---|
| Timestamp delta | Milliseconds |
| Latitude delta | Degrees multiplied by 10,000,000 |
| Longitude delta | Degrees multiplied by 10,000,000 |
| Speed | Centimeters per second |
| Heading | Hundredths of a degree |
| Accuracy | Decimeters |
| Altitude | Decimeters, signed |
| Speed accuracy | Centimeters per second |
| Heading accuracy | Hundredths of a degree |
| Mock-location flag | One byte |

## Motion frames

Each motion frame contains a start-time delta, duration, six axis-statistics records, phone stability, and axis-calibration status.

Each axis-statistics record contains:

1. Minimum, signed and scaled by 1,000
2. Maximum, signed and scaled by 1,000
3. Mean, signed and scaled by 1,000
4. Standard deviation, unsigned and scaled by 1,000
5. RMS, unsigned and scaled by 1,000
6. Source sample count

The six records are longitudinal acceleration, lateral acceleration, vertical acceleration, yaw rate, pitch rate, and roll rate.

## Raw event evidence

Raw motion is only present in event-evidence chunks. Each sample contains a microsecond timestamp delta followed by acceleration XYZ and gyroscope XYZ. All six values are signed and scaled by 1,000.

## Candidate events

Each event contains its identifier, event enum index, start-time delta, duration, confidence in thousandths, minimum, maximum, mean, and a bit field controlling optional data.

Optional fields include speed before, speed after, coordinates, effective speed limit, evidence chunk identifier, and JSON metadata.

## Hourly aggregate

The final section starts with a one-byte presence flag. When present, it contains time range, distance, moving duration, speed statistics, longitudinal statistics, lateral statistics, yaw statistics, location-quality counts, and candidate-event counts.

See `backend_reference/telemetry_decoder.ts` for a compatible TypeScript decoder.
