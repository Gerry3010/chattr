// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:collection';

typedef MapEntryDiff<V> = ({MapEntryStatus status, V? oldValue, V? newValue});

enum MapEntryStatus {
  added,
  changed,
  removed,
}

BigInt calcIterableHash<T>(Iterable<T> iterable, {bool? ignoreOrder}) {
  final newIgnoreOrder = ignoreOrder ?? iterable is! HashSet;

  var hash = BigInt.from(iterable.length);
  for (final (index, value) in iterable.indexed) {
    BigInt newHash = calcHash<T>(value, ignoreOrder: ignoreOrder);
    // If it's an ordered collection (not a Set/HashMap), include index in hash
    if (!newIgnoreOrder) {
      newHash = bigIntHash2(newHash, BigInt.from(index));
    }
    hash = bigIntHash(hash, newHash);
  }
  return hash;
}

/// Generates a hash for a map by hashing its keys and values.
/// This hash is order-independent for the map's entries because `map.keys` and `map.values`
/// iterate in key-insertion order, but `getIterableHash` for unordered types like `HashSet`
/// makes the nested collections order-independent.
BigInt calcMapHash<T>(Map<T, dynamic> map, {bool? ignoreOrder}) {
  final newIgnoreOrder = ignoreOrder ?? map is! HashMap;
  // final keys = newIgnoreOrder ? HashSet.of(map.keys) : map.keys;
  // final values = newIgnoreOrder ? HashSet.of(map.values) : map.values;
  // final keysHash = calcIterableHash(keys, ignoreOrder: ignoreOrder);
  // final valuesHash = calcIterableHash(values, ignoreOrder: ignoreOrder);
  var hash = BigInt.from(map.length);
  for (final (index, entry) in map.entries.indexed) {
    var newHash = calcMapEntryHash(entry, ignoreOrder: newIgnoreOrder);
    if (!newIgnoreOrder) {
      newHash = bigIntHash2(newHash, BigInt.from(index));
    }
    hash = bigIntHash(hash, newHash);
  }
  return hash;
}

/// Generates a hash for a map entry by hashing its key and value.
/// This hash is order-independent for the map's entries because `map.keys` and `map.values`
/// iterate in key-insertion order, but `getIterableHash` for unordered types like `HashSet`
/// makes the nested collections order-independent.
BigInt calcMapEntryHash<K, V>(MapEntry<K, V> entry, {bool? ignoreOrder}) {
  final key = entry.key;
  final value = entry.value;
  final keyHash = calcHash<K>(key, ignoreOrder: ignoreOrder);
  final valueHash = calcHash<V>(value, ignoreOrder: ignoreOrder);
  return bigIntHash(keyHash, valueHash);
}

BigInt calcHash<T>(T value, {bool? ignoreOrder}) {
  switch (value) {
    case Iterable():
      return calcIterableHash(value, ignoreOrder: ignoreOrder);
    case Map():
      return calcMapHash(value, ignoreOrder: ignoreOrder);
    case MapEntry():
      return calcMapEntryHash(value, ignoreOrder: ignoreOrder);
    case BigInt():
      return value as BigInt;
    default:
      return BigInt.from(value.hashCode);
  }
}

// Simple XOR-based hashing for BigInts
BigInt bigIntHash(BigInt bigK, BigInt bigV) => bigK ^ bigV;

BigInt bigIntHash2(BigInt bigK, BigInt bigV) => (bigK + bigV) * (bigK + bigV + BigInt.one) ~/ BigInt.two + bigK;

BigInt getHash<T>(T value, {bool? ignoreOrder}) {
  return calcHash<T>(value, ignoreOrder: ignoreOrder);
}

String getHashString<T>(T value, {bool? ignoreOrder}) {
  final hexStr = getHash<T>(value, ignoreOrder: ignoreOrder).toRadixString(16);
  // Ensure even length for hex string if it's going to be decoded as bytes
  return hexStr.length.isEven ? hexStr : '0$hexStr';
}

Map<T, BigInt> getMapKeysHash<T>(Map<T, dynamic> map, {bool? ignoreOrder}) {
  final mapKeysHash = <T, BigInt>{};
  for (final entry in map.keys) {
    mapKeysHash[entry] = calcHash<T>(entry, ignoreOrder: ignoreOrder);
  }
  return mapKeysHash;
}

Map<T, BigInt> getMapValuesHash<T>(Map<T, dynamic> map, {bool? ignoreOrder}) {
  final mapValuesHash = <T, BigInt>{};
  for (final entry in map.entries) {
    mapValuesHash[entry.key] =
        calcHash<dynamic>(entry.value, ignoreOrder: ignoreOrder);
  }
  return mapValuesHash;
}

Map<BigInt, BigInt> getMapEntriesHash(Map<dynamic, dynamic> map, {bool? ignoreOrder}) {
  final mapEntriesHash = <BigInt, BigInt>{};
  for (final entry in map.entries) {
    final key = calcHash<dynamic>(entry.key, ignoreOrder: ignoreOrder);
    final value = calcHash<dynamic>(entry.value, ignoreOrder: ignoreOrder);
    mapEntriesHash[key] = value;
  }
  return mapEntriesHash;
}

Map<K, MapEntryDiff<V>> getMapDiff<K, V>(Map<K, V>? oldMap, Map<K, V>? newMap) {
  oldMap ??= {};
  newMap ??= {};

  final hashOld = getMapValuesHash(oldMap);
  final hashNew = getMapValuesHash(newMap);

  final diff = <K, MapEntryDiff<V>>{};

  for (final entry in newMap.entries) {
    final key = entry.key;
    final value = entry.value;
    if (!oldMap.containsKey(key)) {
      diff[key] = (
        status: MapEntryStatus.added,
        oldValue: null,
        newValue: value,
      );
    } else {
      final oldHash = hashOld[key];
      final newHash = hashNew[key];
      if (oldHash != newHash) {
        diff[key] = (
          status: MapEntryStatus.changed,
          oldValue: oldMap[key],
          newValue: value,
        );
      }
    }
  }
  for (final entry in oldMap.entries) {
    final key = entry.key;
    if (!newMap.containsKey(key)) {
      diff[key] = (
        status: MapEntryStatus.removed,
        oldValue: entry.value,
        newValue: null,
      );
    } else {
      final oldHash = hashOld[key];
      final newHash = hashNew[key];
      if (oldHash != newHash) {
        diff[key] = (
          status: MapEntryStatus.changed,
          oldValue: entry.value,
          newValue: newMap[key],
        );
      }
    }
  }

  return diff;
}

/*
Uint8List _serializeBigInt(BigInt bi) {
  Uint8List array = Uint8List((bi.bitLength / 8).ceil());
  for (int i = 0; i < array.length; i++) {
    array[i] = (bi >> (i * 8)).toUnsigned(8).toInt();
  }
  return array;
}*/
