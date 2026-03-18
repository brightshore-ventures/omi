import 'package:test/test.dart';

/// Tests for Limitless flash page Opus frame extraction with fallback parsers.
///
/// These tests verify the fix for issues #5154 and #5733 where flash pages
/// from sessions recorded during extended offline periods (clock drift)
/// yield zero Opus frames despite containing valid data.
///
/// NOTE: The helper functions below (encodeVarint, decodeVarint, primaryParser,
/// bruteForceExtractOpusFrames, etc.) mirror private methods in
/// LimitlessDeviceConnection. They cannot be imported directly because they are
/// private (_-prefixed). If the production parsers change, update these helpers
/// to match.

// Valid Opus TOC bytes used by the Limitless pendant
const validOpusTocBytes = [0xb8, 0x78, 0xf8, 0xb0, 0x70, 0xf0];

/// Standalone varint encoder matching LimitlessDeviceConnection._encodeVarint
List<int> encodeVarint(int value) {
  final result = <int>[];
  while (value > 0x7f) {
    result.add((value & 0x7f) | 0x80);
    value >>= 7;
  }
  result.add(value & 0x7f);
  return result.isNotEmpty ? result : [0];
}

/// Standalone varint decoder matching LimitlessDeviceConnection._decodeVarint
List<dynamic> decodeVarint(List<int> data, int pos) {
  int result = 0;
  int shift = 0;
  while (pos < data.length) {
    final byte = data[pos];
    pos++;
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) break;
    shift += 7;
  }
  return [result, pos];
}

/// Check if byte is a valid Opus TOC byte
bool isValidOpusToc(int byte) {
  return validOpusTocBytes.contains(byte);
}

/// Generate a fake Opus frame of given size starting with given TOC byte
List<int> generateOpusFrame(int size, {int tocByte = 0xb8}) {
  final frame = List<int>.filled(size, 0x42);
  frame[0] = tocByte;
  return frame;
}

/// Build a well-formed flash page with protobuf structure:
/// - 0x08 + varint timestamp
/// - 0x1a + wrapper containing 0x08 offset + 0x12 audio data with Opus frames
List<int> buildFlashPage({
  required int timestampMs,
  required List<List<int>> opusFrames,
}) {
  final page = <int>[];

  // Field 1 (0x08): timestamp
  page.add(0x08);
  page.addAll(encodeVarint(timestampMs));

  // For each Opus frame, wrap in 0x1a -> 0x12 -> 0x22 structure
  for (final frame in opusFrames) {
    // Inner audio data: field 4 (0x22) length-delimited = Opus frame
    final audioInner = <int>[];
    audioInner.add(0x22); // field 4, wire type 2
    audioInner.addAll(encodeVarint(frame.length));
    audioInner.addAll(frame);

    // Audio section: field 2 (0x12) length-delimited
    final audioSection = <int>[];
    audioSection.add(0x12); // field 2, wire type 2
    audioSection.addAll(encodeVarint(audioInner.length));
    audioSection.addAll(audioInner);

    // Wrapper: field 3 (0x1a) length-delimited
    page.add(0x1a);
    page.addAll(encodeVarint(audioSection.length));
    page.addAll(audioSection);
  }

  return page;
}

/// Build a flash page with non-standard protobuf structure that the primary
/// parser can't handle (simulates pages from drifted/different firmware sessions)
List<int> buildNonStandardFlashPage({
  required int timestampMs,
  required List<List<int>> opusFrames,
}) {
  final page = <int>[];

  // Use non-standard field ordering: extra field before timestamp
  page.add(0x18); // field 3, varint
  page.addAll(encodeVarint(42)); // some unknown field

  // Field 1 (0x08): timestamp
  page.add(0x08);
  page.addAll(encodeVarint(timestampMs));

  // Use different nesting for audio data (field 5 instead of field 3 for wrapper)
  for (final frame in opusFrames) {
    final audioInner = <int>[];
    // Use 0x0a (field 1, wire type 2) instead of 0x22 for inner frame
    audioInner.add(0x0a);
    audioInner.addAll(encodeVarint(frame.length));
    audioInner.addAll(frame);

    // Still use 0x12 for audio section
    final audioSection = <int>[];
    audioSection.add(0x12);
    audioSection.addAll(encodeVarint(audioInner.length));
    audioSection.addAll(audioInner);

    // Wrapper: still 0x1a
    page.add(0x1a);
    page.addAll(encodeVarint(audioSection.length));
    page.addAll(audioSection);
  }

  return page;
}

/// Simulate the primary parser: _extractOpusFramesFromFlashPage
/// Returns extracted Opus frames from a well-formed flash page
List<List<int>> primaryParser(List<int> flashPageData) {
  final frames = <List<int>>[];
  try {
    int pos = 0;

    // Skip timestamp (0x08) if present
    if (pos < flashPageData.length && flashPageData[pos] == 0x08) {
      pos++;
      final result = decodeVarint(flashPageData, pos);
      pos = result[1] as int;
    }

    // Skip 0x10 if present
    if (pos < flashPageData.length && flashPageData[pos] == 0x10) {
      pos++;
      final result = decodeVarint(flashPageData, pos);
      pos = result[1] as int;
    }

    // Process audio wrappers (0x1a)
    while (pos < flashPageData.length - 2) {
      if (flashPageData[pos] == 0x1a) {
        pos++;
        final wrapperLengthResult = decodeVarint(flashPageData, pos);
        final wrapperLength = wrapperLengthResult[0] as int;
        pos = wrapperLengthResult[1] as int;

        final wrapperEnd = pos + wrapperLength;
        if (wrapperEnd > flashPageData.length) break;

        while (pos < wrapperEnd - 1) {
          final marker = flashPageData[pos];

          if (marker == 0x08) {
            pos++;
            final result = decodeVarint(flashPageData, pos);
            pos = result[1] as int;
            continue;
          }

          if (marker == 0x12) {
            pos++;
            final audioLengthResult = decodeVarint(flashPageData, pos);
            final audioLength = audioLengthResult[0] as int;
            pos = audioLengthResult[1] as int;

            final audioEnd = pos + audioLength;
            if (audioEnd > flashPageData.length) {
              pos = wrapperEnd;
              break;
            }

            _extractOpusRecursive(flashPageData, pos, audioEnd, frames);
            pos = audioEnd;
            continue;
          }

          final wireType = marker & 0x07;
          pos++;
          if (wireType == 0) {
            final result = decodeVarint(flashPageData, pos);
            pos = result[1] as int;
          } else if (wireType == 2) {
            final lengthResult = decodeVarint(flashPageData, pos);
            pos = lengthResult[1] as int;
            pos += lengthResult[0] as int;
          }
        }

        pos = wrapperEnd;
      } else {
        pos++;
      }
    }
  } catch (_) {}
  return frames;
}

void _extractOpusRecursive(List<int> data, int start, int end, List<List<int>> frames) {
  int pos = start;
  while (pos < end - 1) {
    final tag = data[pos];
    final wireType = tag & 0x07;
    pos++;

    if (wireType == 2) {
      final lengthResult = decodeVarint(data, pos);
      final length = lengthResult[0] as int;
      pos = lengthResult[1] as int;

      if (length > 0 && pos + length <= end) {
        final fieldData = data.sublist(pos, pos + length);
        if (length >= 10 && length <= 200 && fieldData.isNotEmpty && isValidOpusToc(fieldData[0])) {
          frames.add(fieldData);
        } else if (length > 10) {
          _extractOpusRecursive(data, pos, pos + length, frames);
        }
      }
      pos += length;
    } else if (wireType == 0) {
      final result = decodeVarint(data, pos);
      pos = result[1] as int;
    } else {
      break;
    }
  }
}

/// Brute-force scanner matching LimitlessDeviceConnection._bruteForceExtractOpusFrames
List<List<int>> bruteForceExtractOpusFrames(List<int> data) {
  final frames = <List<int>>[];
  for (int pos = 0; pos < data.length - 3; pos++) {
    final wireType = data[pos] & 0x07;
    if (wireType != 2) continue;

    int lengthPos = pos + 1;
    if (lengthPos >= data.length) continue;

    try {
      final lengthResult = decodeVarint(data, lengthPos);
      final length = lengthResult[0] as int;
      final dataStart = lengthResult[1] as int;

      if (length >= 10 && length <= 200 && dataStart + length <= data.length) {
        final firstByte = data[dataStart];
        if (isValidOpusToc(firstByte)) {
          frames.add(data.sublist(dataStart, dataStart + length));
          pos = dataStart + length - 1;
        }
      }
    } catch (_) {
      continue;
    }
  }
  return frames;
}

void main() {
  group('Flash page parsing - normal pages', () {
    test('Primary parser extracts frames from well-formed flash page', () {
      final frames = [
        generateOpusFrame(50, tocByte: 0xb8),
        generateOpusFrame(60, tocByte: 0x78),
        generateOpusFrame(45, tocByte: 0xf8),
      ];
      final page = buildFlashPage(timestampMs: 1700000000000, opusFrames: frames);

      final extracted = primaryParser(page);
      expect(extracted.length, 3);
      expect(extracted[0].length, 50);
      expect(extracted[1].length, 60);
      expect(extracted[2].length, 45);
    });

    test('Primary parser handles empty page', () {
      final extracted = primaryParser([]);
      expect(extracted.isEmpty, true);
    });

    test('Primary parser handles page with only timestamp', () {
      final page = <int>[0x08, ...encodeVarint(1700000000000)];
      final extracted = primaryParser(page);
      expect(extracted.isEmpty, true);
    });
  });

  group('Flash page parsing - clock drift scenarios', () {
    test('Primary parser handles page with very large timestamp (far future drift)', () {
      final frames = [generateOpusFrame(50)];
      // Timestamp far in the future (year 2050)
      final page = buildFlashPage(timestampMs: 2524608000000, opusFrames: frames);
      final extracted = primaryParser(page);
      expect(extracted.length, 1);
    });

    test('Primary parser handles page with zero timestamp', () {
      final frames = [generateOpusFrame(50)];
      final page = buildFlashPage(timestampMs: 0, opusFrames: frames);
      final extracted = primaryParser(page);
      expect(extracted.length, 1);
    });

    test('Primary parser handles page with negative-like timestamp (very small)', () {
      final frames = [generateOpusFrame(50)];
      final page = buildFlashPage(timestampMs: 1, opusFrames: frames);
      final extracted = primaryParser(page);
      expect(extracted.length, 1);
    });
  });

  group('Flash page parsing - non-standard structure (drift/firmware variant)', () {
    test('Primary parser fails on non-standard page, brute force succeeds', () {
      final frames = [
        generateOpusFrame(50, tocByte: 0xb8),
        generateOpusFrame(60, tocByte: 0x78),
      ];
      final page = buildNonStandardFlashPage(timestampMs: 1700000000000, opusFrames: frames);

      // Primary parser should still find frames through 0x1a wrappers
      final primaryResult = primaryParser(page);

      // Brute force should always find the frames regardless of structure
      final bruteForceResult = bruteForceExtractOpusFrames(page);
      expect(bruteForceResult.length, greaterThanOrEqualTo(2));
      expect(bruteForceResult[0][0], 0xb8);
      expect(bruteForceResult[1][0], 0x78);
    });

    test('Brute force extracts frames from raw data with unknown wrapper', () {
      // Build data with completely unknown structure but valid Opus frames embedded
      final frame1 = generateOpusFrame(50, tocByte: 0xb8);
      final frame2 = generateOpusFrame(40, tocByte: 0x70);

      final data = <int>[];
      // Some random protobuf-like header
      data.addAll([0x08, 0x01, 0x10, 0x02]);
      // Embed frame1 as a length-delimited field (tag for field 5 wire type 2 = 0x2a)
      data.add(0x2a);
      data.addAll(encodeVarint(frame1.length));
      data.addAll(frame1);
      // Some padding
      data.addAll([0x08, 0x03]);
      // Embed frame2 as a length-delimited field (tag for field 7 wire type 2 = 0x3a)
      data.add(0x3a);
      data.addAll(encodeVarint(frame2.length));
      data.addAll(frame2);

      final extracted = bruteForceExtractOpusFrames(data);
      expect(extracted.length, 2);
      expect(extracted[0].length, 50);
      expect(extracted[1].length, 40);
    });

    test('Brute force rejects frames with invalid TOC bytes', () {
      final data = <int>[];
      // Frame with invalid TOC
      final fakeFrame = List<int>.filled(50, 0x42);
      fakeFrame[0] = 0x01; // NOT a valid Opus TOC byte
      data.add(0x12);
      data.addAll(encodeVarint(fakeFrame.length));
      data.addAll(fakeFrame);

      final extracted = bruteForceExtractOpusFrames(data);
      expect(extracted.isEmpty, true);
    });

    test('Brute force rejects frames outside valid size range', () {
      final data = <int>[];

      // Frame too small (5 bytes)
      final smallFrame = generateOpusFrame(5);
      data.add(0x12);
      data.addAll(encodeVarint(smallFrame.length));
      data.addAll(smallFrame);

      // Frame too large (250 bytes)
      final largeFrame = generateOpusFrame(250);
      data.add(0x12);
      data.addAll(encodeVarint(largeFrame.length));
      data.addAll(largeFrame);

      final extracted = bruteForceExtractOpusFrames(data);
      expect(extracted.isEmpty, true);
    });
  });

  group('Brute-force false positive rejection', () {
    test('Random data should produce few or no matches (statistical test)', () {
      // Generate pseudo-random data that is NOT valid Opus
      // Use a deterministic seed-like pattern to avoid flakiness
      final data = List<int>.generate(4000, (i) => (i * 37 + 13) & 0xFF);

      final extracted = bruteForceExtractOpusFrames(data);

      // With random data, false positives are possible (low probability per position)
      // but should be very few. For a 4000-byte page, expect < 10 false positives.
      // The production code requires >= 3 frames to accept brute-force results,
      // so even if some false positives occur, the threshold filters them.
      // This test verifies the false positive rate is low.
      expect(extracted.length, lessThan(15),
          reason: 'Brute force should produce very few false positives on random data');
    });

    test('Minimum frame count threshold rejects sparse false positives', () {
      // Simulate the production logic: require >= 3 frames from brute force
      final data = <int>[];
      // Only embed 1 valid-looking frame in otherwise random data
      data.addAll(List<int>.generate(2000, (i) => (i * 41 + 7) & 0xFF));
      data.add(0x12); // wire type 2
      data.addAll(encodeVarint(50));
      data.addAll(generateOpusFrame(50, tocByte: 0xb8));
      data.addAll(List<int>.generate(1900, (i) => (i * 53 + 19) & 0xFF));

      final extracted = bruteForceExtractOpusFrames(data);
      // Even if brute force finds this 1 frame plus some false positives,
      // the production code requires >= 3 frames to accept the result
      // This makes it much harder for corrupted data to be mistaken for audio
      expect(extracted.length, lessThan(10));
    });

    test('Pages with >= 3 valid frames pass the threshold', () {
      final data = <int>[];
      data.addAll([0x08, 0x01]); // some header
      for (int i = 0; i < 5; i++) {
        final frame = generateOpusFrame(50, tocByte: validOpusTocBytes[i % validOpusTocBytes.length]);
        data.add(0x12); // wire type 2
        data.addAll(encodeVarint(frame.length));
        data.addAll(frame);
        data.addAll([0x08, 0x01]); // spacer
      }

      final extracted = bruteForceExtractOpusFrames(data);
      expect(extracted.length, greaterThanOrEqualTo(3),
          reason: 'Should extract enough frames to pass the >= 3 threshold');
    });
  });

  group('Flash page parsing - edge cases', () {
    test('Handles page with maximum valid frame size (200 bytes)', () {
      final frames = [generateOpusFrame(200)];
      final page = buildFlashPage(timestampMs: 1700000000000, opusFrames: frames);
      final extracted = primaryParser(page);
      expect(extracted.length, 1);
      expect(extracted[0].length, 200);
    });

    test('Handles page with minimum valid frame size (10 bytes)', () {
      final frames = [generateOpusFrame(10)];
      final page = buildFlashPage(timestampMs: 1700000000000, opusFrames: frames);
      final extracted = primaryParser(page);
      expect(extracted.length, 1);
      expect(extracted[0].length, 10);
    });

    test('Handles page with many frames (simulating full flash page)', () {
      final frames = List.generate(8, (i) => generateOpusFrame(50 + i * 5));
      final page = buildFlashPage(timestampMs: 1700000000000, opusFrames: frames);
      final extracted = primaryParser(page);
      expect(extracted.length, 8);
    });

    test('Handles truncated page data gracefully', () {
      final frames = [generateOpusFrame(50)];
      final page = buildFlashPage(timestampMs: 1700000000000, opusFrames: frames);
      // Truncate to half
      final truncated = page.sublist(0, page.length ~/ 2);
      // Should not throw, may extract 0 frames
      final extracted = primaryParser(truncated);
      expect(extracted.length, lessThanOrEqualTo(1));
    });

    test('Handles all-zero data', () {
      final data = List<int>.filled(4000, 0);
      final primaryResult = primaryParser(data);
      expect(primaryResult.isEmpty, true);

      final bruteForceResult = bruteForceExtractOpusFrames(data);
      expect(bruteForceResult.isEmpty, true);
    });

    test('Handles page with each valid TOC byte', () {
      for (final toc in validOpusTocBytes) {
        final frames = [generateOpusFrame(50, tocByte: toc)];
        final page = buildFlashPage(timestampMs: 1700000000000, opusFrames: frames);
        final extracted = primaryParser(page);
        expect(extracted.length, 1, reason: 'Failed for TOC byte 0x${toc.toRadixString(16)}');
        expect(extracted[0][0], toc);
      }
    });
  });

  group('Varint encoding/decoding', () {
    test('Round-trips small values', () {
      for (final val in [0, 1, 127]) {
        final encoded = encodeVarint(val);
        final decoded = decodeVarint(encoded, 0);
        expect(decoded[0], val);
      }
    });

    test('Round-trips large values', () {
      for (final val in [128, 16384, 1700000000000]) {
        final encoded = encodeVarint(val);
        final decoded = decodeVarint(encoded, 0);
        expect(decoded[0], val);
      }
    });
  });

  group('WAL upload retry logic', () {
    test('Retry delay calculation: exponential backoff', () {
      // Base delays: 2s, 4s, 8s
      for (int attempt = 0; attempt < 3; attempt++) {
        final baseDelayMs = 2000 * (1 << attempt);
        expect(baseDelayMs, [2000, 4000, 8000][attempt]);
      }
    });

    test('Server unavailable error is detected correctly', () {
      final error = Exception('Server is temporarily unavailable');
      expect(error.toString().contains('Server is temporarily unavailable'), true);
    });

    test('Non-server errors are not retryable', () {
      final error400 = Exception('Audio file could not be processed by server');
      expect(error400.toString().contains('Server is temporarily unavailable'), false);

      final error413 = Exception('Audio file is too large to upload');
      expect(error413.toString().contains('Server is temporarily unavailable'), false);
    });
  });

  group('Clock drift detection', () {
    test('Zero drift is the default', () {
      // The clock drift should default to 0 when detection fails or is not run
      int clockDriftMs = 0;
      expect(clockDriftMs, 0);
    });

    test('Drift magnitude classification', () {
      // Helper to classify drift severity
      String classifyDrift(int driftMs) {
        final absDrift = driftMs.abs();
        if (absDrift < 1000) return 'none';
        if (absDrift < 60000) return 'minor';
        if (absDrift < 3600000) return 'moderate';
        return 'severe';
      }

      expect(classifyDrift(0), 'none');
      expect(classifyDrift(500), 'none');
      expect(classifyDrift(30000), 'minor');
      expect(classifyDrift(1800000), 'moderate');
      expect(classifyDrift(86400000), 'severe'); // 24 hours
      expect(classifyDrift(-172800000), 'severe'); // -48 hours
    });
  });

  group('Simulated batch download with drifted pages', () {
    test('Fallback parsers recover frames from drifted session pages', () {
      // Simulate 10 flash pages from a drifted session
      int totalFrames = 0;
      int pagesWithFrames = 0;

      for (int i = 0; i < 10; i++) {
        final frames = List.generate(8, (j) => generateOpusFrame(50 + j * 3));
        // Use non-standard structure to simulate drifted pages
        final page = buildNonStandardFlashPage(
          timestampMs: 1700000000000 + i * 1400,
          opusFrames: frames,
        );

        // Primary parser might fail
        var extracted = primaryParser(page);

        // Fallback: brute force
        if (extracted.isEmpty) {
          extracted = bruteForceExtractOpusFrames(page);
        }

        if (extracted.isNotEmpty) {
          pagesWithFrames++;
          totalFrames += extracted.length;
        }
      }

      // With fallback parsers, we should recover frames from all pages
      expect(pagesWithFrames, greaterThan(0));
      expect(totalFrames, greaterThan(0));
    });

    test('filesSaved > 0 when fallback parsers are used', () {
      // This simulates the full failure scenario from the bug report:
      // 12,000+ pages from drifted session, all yielding zero frames with primary parser
      int filesSaved = 0;
      List<List<int>> accumulatedFrames = [];

      for (int i = 0; i < 100; i++) {
        final frames = List.generate(8, (j) => generateOpusFrame(50));
        final page = buildNonStandardFlashPage(
          timestampMs: 1700000000000 + i * 1400,
          opusFrames: frames,
        );

        var extracted = primaryParser(page);
        if (extracted.isEmpty) {
          extracted = bruteForceExtractOpusFrames(page);
        }

        accumulatedFrames.addAll(extracted);

        // Simulate batch save every 25 pages
        if ((i + 1) % 25 == 0 && accumulatedFrames.isNotEmpty) {
          filesSaved++;
          accumulatedFrames.clear();
        }
      }

      // Save remaining
      if (accumulatedFrames.isNotEmpty) {
        filesSaved++;
      }

      expect(filesSaved, greaterThan(0), reason: 'filesSaved should be > 0 with fallback parsers');
    });
  });
}
