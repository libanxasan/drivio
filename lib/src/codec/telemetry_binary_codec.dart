import 'dart:convert';
import 'dart:typed_data';

import '../model/axis_statistics.dart';
import '../model/event_candidate.dart';
import '../model/hourly_aggregate.dart';
import '../model/location_sample.dart';
import '../model/motion_frame.dart';
import '../model/raw_motion_sample.dart';
import '../model/telemetry_chunk.dart';
import '../model/vector3_value.dart';
import 'compact_binary.dart';

/// Versioned compact binary codec for telemetry chunks.
class TelemetryBinaryCodec {
  /// Current schema version.
  static const int schemaVersion = 1;

  static const List<int> _magic = <int>[0x44, 0x54, 0x4c, 0x31];
  static const double _motionScale = 1000;

  /// Encodes a chunk.
  Uint8List encode(TelemetryChunk chunk) {
    final writer = CompactBinaryWriter();
    writer.writeBytes(_magic);
    writer.writeVarUint(chunk.schemaVersion);
    writer.writeVarUint(chunk.type.index);
    writer.writeString(chunk.tripId);
    writer.writeString(chunk.chunkId);
    writer.writeVarUint(chunk.chunkIndex);
    writer.writeVarUint(chunk.startedAtMillis);
    writer.writeVarUint(chunk.endedAtMillis - chunk.startedAtMillis);

    _writeLocations(writer, chunk.locations, chunk.startedAtMillis);
    _writeFrames(writer, chunk.motionFrames, chunk.startedAtMillis);
    _writeRawMotion(writer, chunk.rawMotionSamples, chunk.startedAtMillis);
    _writeEvents(writer, chunk.events, chunk.startedAtMillis);
    _writeHourly(writer, chunk.hourlyAggregate);
    return writer.takeBytes();
  }

  /// Decodes a chunk.
  TelemetryChunk decode(Uint8List bytes) {
    final reader = CompactBinaryReader(bytes);
    final magic = reader.readBytes(_magic.length);
    for (var index = 0; index < _magic.length; index++) {
      if (magic[index] != _magic[index]) {
        throw const FormatException('Invalid telemetry chunk magic.');
      }
    }

    final version = reader.readVarUint();
    if (version != schemaVersion) {
      throw FormatException('Unsupported telemetry schema version: $version.');
    }

    final type = TelemetryChunkType.values[reader.readVarUint()];
    final tripId = reader.readString();
    final chunkId = reader.readString();
    final chunkIndex = reader.readVarUint();
    final startedAtMillis = reader.readVarUint();
    final endedAtMillis = startedAtMillis + reader.readVarUint();

    return TelemetryChunk(
      schemaVersion: version,
      tripId: tripId,
      chunkId: chunkId,
      chunkIndex: chunkIndex,
      type: type,
      startedAtMillis: startedAtMillis,
      endedAtMillis: endedAtMillis,
      locations: _readLocations(reader, startedAtMillis),
      motionFrames: _readFrames(reader, startedAtMillis),
      rawMotionSamples: _readRawMotion(reader, startedAtMillis),
      events: _readEvents(reader, startedAtMillis),
      hourlyAggregate: _readHourly(reader),
    );
  }

  void _writeLocations(
    CompactBinaryWriter writer,
    List<LocationSample> values,
    int chunkStartMillis,
  ) {
    writer.writeVarUint(values.length);
    var previousTime = chunkStartMillis;
    var previousLatitude = 0;
    var previousLongitude = 0;
    for (final value in values) {
      writer.writeVarUint(value.timestampMillis - previousTime);
      writer.writeVarInt(value.latitudeE7 - previousLatitude);
      writer.writeVarInt(value.longitudeE7 - previousLongitude);
      writer.writeVarUint((value.speedMps * 100).round().clamp(0, 1000000).toInt());
      writer.writeVarUint(
        (value.headingDegrees * 100).round().clamp(0, 36000).toInt(),
      );
      writer.writeVarUint(
        (value.accuracyMeters * 10).round().clamp(0, 1000000).toInt(),
      );
      writer.writeVarInt((value.altitudeMeters * 10).round());
      writer.writeVarUint(
        (value.speedAccuracyMps * 100).round().clamp(0, 1000000).toInt(),
      );
      writer.writeVarUint(
        (value.headingAccuracyDegrees * 100).round().clamp(0, 36000).toInt(),
      );
      writer.writeByte(value.isMocked ? 1 : 0);
      previousTime = value.timestampMillis;
      previousLatitude = value.latitudeE7;
      previousLongitude = value.longitudeE7;
    }
  }

  List<LocationSample> _readLocations(
    CompactBinaryReader reader,
    int chunkStartMillis,
  ) {
    final count = reader.readVarUint();
    final values = <LocationSample>[];
    var previousTime = chunkStartMillis;
    var previousLatitude = 0;
    var previousLongitude = 0;
    for (var index = 0; index < count; index++) {
      final timestamp = previousTime + reader.readVarUint();
      final latitudeE7 = previousLatitude + reader.readVarInt();
      final longitudeE7 = previousLongitude + reader.readVarInt();
      final speed = reader.readVarUint() / 100;
      final heading = reader.readVarUint() / 100;
      final accuracy = reader.readVarUint() / 10;
      final altitude = reader.readVarInt() / 10;
      final speedAccuracy = reader.readVarUint() / 100;
      final headingAccuracy = reader.readVarUint() / 100;
      final isMocked = reader.readByte() == 1;
      values.add(
        LocationSample(
          timestampMillis: timestamp,
          latitude: latitudeE7 / 10000000,
          longitude: longitudeE7 / 10000000,
          speedMps: speed,
          headingDegrees: heading,
          accuracyMeters: accuracy,
          altitudeMeters: altitude,
          speedAccuracyMps: speedAccuracy,
          headingAccuracyDegrees: headingAccuracy,
          isMocked: isMocked,
        ),
      );
      previousTime = timestamp;
      previousLatitude = latitudeE7;
      previousLongitude = longitudeE7;
    }
    return values;
  }

  void _writeFrames(
    CompactBinaryWriter writer,
    List<MotionFrame> values,
    int chunkStartMillis,
  ) {
    writer.writeVarUint(values.length);
    for (final value in values) {
      writer.writeVarUint(value.startedAtMillis - chunkStartMillis);
      writer.writeVarUint(value.durationMillis);
      _writeAxis(writer, value.longitudinalAcceleration);
      _writeAxis(writer, value.lateralAcceleration);
      _writeAxis(writer, value.verticalAcceleration);
      _writeAxis(writer, value.yawRate);
      _writeAxis(writer, value.pitchRate);
      _writeAxis(writer, value.rollRate);
      writer.writeVarUint((value.phoneStability * 1000).round().clamp(0, 1000).toInt());
      writer.writeByte(value.axisMappingCalibrated ? 1 : 0);
    }
  }

  List<MotionFrame> _readFrames(
    CompactBinaryReader reader,
    int chunkStartMillis,
  ) {
    final count = reader.readVarUint();
    return List<MotionFrame>.generate(count, (_) {
      final start = chunkStartMillis + reader.readVarUint();
      final duration = reader.readVarUint();
      return MotionFrame(
        startedAtMillis: start,
        durationMillis: duration,
        longitudinalAcceleration: _readAxis(reader),
        lateralAcceleration: _readAxis(reader),
        verticalAcceleration: _readAxis(reader),
        yawRate: _readAxis(reader),
        pitchRate: _readAxis(reader),
        rollRate: _readAxis(reader),
        phoneStability: reader.readVarUint() / 1000,
        axisMappingCalibrated: reader.readByte() == 1,
      );
    });
  }

  void _writeAxis(CompactBinaryWriter writer, AxisStatistics value) {
    writer.writeVarInt((value.minimum * _motionScale).round());
    writer.writeVarInt((value.maximum * _motionScale).round());
    writer.writeVarInt((value.mean * _motionScale).round());
    writer.writeVarUint((value.standardDeviation * _motionScale).round());
    writer.writeVarUint((value.rms * _motionScale).round());
    writer.writeVarUint(value.sampleCount);
  }

  AxisStatistics _readAxis(CompactBinaryReader reader) {
    return AxisStatistics(
      minimum: reader.readVarInt() / _motionScale,
      maximum: reader.readVarInt() / _motionScale,
      mean: reader.readVarInt() / _motionScale,
      standardDeviation: reader.readVarUint() / _motionScale,
      rms: reader.readVarUint() / _motionScale,
      sampleCount: reader.readVarUint(),
    );
  }

  void _writeRawMotion(
    CompactBinaryWriter writer,
    List<RawMotionSample> values,
    int chunkStartMillis,
  ) {
    writer.writeVarUint(values.length);
    var previousMicros = chunkStartMillis * 1000;
    for (final value in values) {
      writer.writeVarUint(value.timestampMicros - previousMicros);
      _writeVector(writer, value.userAcceleration);
      _writeVector(writer, value.gyroscope);
      previousMicros = value.timestampMicros;
    }
  }

  List<RawMotionSample> _readRawMotion(
    CompactBinaryReader reader,
    int chunkStartMillis,
  ) {
    final count = reader.readVarUint();
    final values = <RawMotionSample>[];
    var previousMicros = chunkStartMillis * 1000;
    for (var index = 0; index < count; index++) {
      final timestamp = previousMicros + reader.readVarUint();
      values.add(
        RawMotionSample(
          timestampMicros: timestamp,
          userAcceleration: _readVector(reader),
          gyroscope: _readVector(reader),
        ),
      );
      previousMicros = timestamp;
    }
    return values;
  }

  void _writeVector(CompactBinaryWriter writer, Vector3Value value) {
    writer.writeVarInt((value.x * _motionScale).round());
    writer.writeVarInt((value.y * _motionScale).round());
    writer.writeVarInt((value.z * _motionScale).round());
  }

  Vector3Value _readVector(CompactBinaryReader reader) {
    return Vector3Value(
      reader.readVarInt() / _motionScale,
      reader.readVarInt() / _motionScale,
      reader.readVarInt() / _motionScale,
    );
  }

  void _writeEvents(
    CompactBinaryWriter writer,
    List<TelemetryEventCandidate> values,
    int chunkStartMillis,
  ) {
    writer.writeVarUint(values.length);
    for (final value in values) {
      writer.writeString(value.id);
      writer.writeVarUint(value.type.index);
      writer.writeVarUint(value.startedAtMillis - chunkStartMillis);
      writer.writeVarUint(value.durationMillis);
      writer.writeVarUint((value.confidence * 1000).round().clamp(0, 1000).toInt());
      writer.writeVarInt((value.minimumValue * _motionScale).round());
      writer.writeVarInt((value.maximumValue * _motionScale).round());
      writer.writeVarInt((value.meanValue * _motionScale).round());

      var flags = 0;
      if (value.speedBeforeMps != null) flags |= 1;
      if (value.speedAfterMps != null) flags |= 2;
      if (value.latitude != null && value.longitude != null) flags |= 4;
      if (value.effectiveSpeedLimitKph != null) flags |= 8;
      if (value.evidenceChunkId != null) flags |= 16;
      if (value.metadata.isNotEmpty) flags |= 32;
      writer.writeVarUint(flags);

      if ((flags & 1) != 0) {
        writer.writeVarUint((value.speedBeforeMps! * 100).round());
      }
      if ((flags & 2) != 0) {
        writer.writeVarUint((value.speedAfterMps! * 100).round());
      }
      if ((flags & 4) != 0) {
        writer.writeVarInt((value.latitude! * 10000000).round());
        writer.writeVarInt((value.longitude! * 10000000).round());
      }
      if ((flags & 8) != 0) {
        writer.writeVarUint((value.effectiveSpeedLimitKph! * 100).round());
      }
      if ((flags & 16) != 0) writer.writeString(value.evidenceChunkId!);
      if ((flags & 32) != 0) writer.writeString(jsonEncode(value.metadata));
    }
  }

  List<TelemetryEventCandidate> _readEvents(
    CompactBinaryReader reader,
    int chunkStartMillis,
  ) {
    final count = reader.readVarUint();
    return List<TelemetryEventCandidate>.generate(count, (_) {
      final id = reader.readString();
      final type = TelemetryEventType.values[reader.readVarUint()];
      final startedAt = chunkStartMillis + reader.readVarUint();
      final duration = reader.readVarUint();
      final confidence = reader.readVarUint() / 1000;
      final minimum = reader.readVarInt() / _motionScale;
      final maximum = reader.readVarInt() / _motionScale;
      final mean = reader.readVarInt() / _motionScale;
      final flags = reader.readVarUint();
      final speedBefore = (flags & 1) != 0 ? reader.readVarUint() / 100 : null;
      final speedAfter = (flags & 2) != 0 ? reader.readVarUint() / 100 : null;
      double? latitude;
      double? longitude;
      if ((flags & 4) != 0) {
        latitude = reader.readVarInt() / 10000000;
        longitude = reader.readVarInt() / 10000000;
      }
      final limit = (flags & 8) != 0 ? reader.readVarUint() / 100 : null;
      final evidence = (flags & 16) != 0 ? reader.readString() : null;
      final metadata = (flags & 32) != 0
          ? (jsonDecode(reader.readString()) as Map<String, dynamic>)
              .cast<String, Object?>()
          : const <String, Object?>{};
      return TelemetryEventCandidate(
        id: id,
        type: type,
        startedAtMillis: startedAt,
        endedAtMillis: startedAt + duration,
        confidence: confidence,
        minimumValue: minimum,
        maximumValue: maximum,
        meanValue: mean,
        speedBeforeMps: speedBefore,
        speedAfterMps: speedAfter,
        latitude: latitude,
        longitude: longitude,
        effectiveSpeedLimitKph: limit,
        evidenceChunkId: evidence,
        metadata: metadata,
      );
    });
  }

  void _writeHourly(
    CompactBinaryWriter writer,
    HourlyTelemetryAggregate? value,
  ) {
    writer.writeByte(value == null ? 0 : 1);
    if (value == null) return;
    writer.writeVarUint(value.hourStartedAtMillis);
    writer.writeVarUint(value.hourEndedAtMillis - value.hourStartedAtMillis);
    writer.writeVarUint(value.distanceMeters.round());
    writer.writeVarUint(value.movingDurationMillis);
    _writeAxis(writer, value.speed);
    _writeAxis(writer, value.longitudinalAcceleration);
    _writeAxis(writer, value.lateralAcceleration);
    _writeAxis(writer, value.yawRate);
    writer.writeVarUint(value.locationSampleCount);
    writer.writeVarUint(value.validLocationSampleCount);
    writer.writeVarUint(value.eventCounts.length);
    for (final entry in value.eventCounts.entries) {
      writer.writeVarUint(entry.key.index);
      writer.writeVarUint(entry.value);
    }
  }

  HourlyTelemetryAggregate? _readHourly(CompactBinaryReader reader) {
    if (reader.readByte() == 0) return null;
    final start = reader.readVarUint();
    final duration = reader.readVarUint();
    final distance = reader.readVarUint().toDouble();
    final movingDuration = reader.readVarUint();
    final speed = _readAxis(reader);
    final longitudinal = _readAxis(reader);
    final lateral = _readAxis(reader);
    final yaw = _readAxis(reader);
    final locationCount = reader.readVarUint();
    final validLocationCount = reader.readVarUint();
    final eventCount = reader.readVarUint();
    final events = <TelemetryEventType, int>{};
    for (var index = 0; index < eventCount; index++) {
      events[TelemetryEventType.values[reader.readVarUint()]] =
          reader.readVarUint();
    }
    return HourlyTelemetryAggregate(
      hourStartedAtMillis: start,
      hourEndedAtMillis: start + duration,
      distanceMeters: distance,
      movingDurationMillis: movingDuration,
      speed: speed,
      longitudinalAcceleration: longitudinal,
      lateralAcceleration: lateral,
      yawRate: yaw,
      locationSampleCount: locationCount,
      validLocationSampleCount: validLocationCount,
      eventCounts: events,
    );
  }
}
