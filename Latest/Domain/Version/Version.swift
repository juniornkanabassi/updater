//
//  Version.swift
//  Latest
//
//  Created by Max Langer on 01.11.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import Foundation

/// An app's version and build identifiers. Identity compares the stored identifiers,
/// with all empty forms treated alike. Vendor-specific update precedence is separate.
struct Version: Hashable, Sendable {

  /// The version number itself
  let versionNumber: String?

  /// The build number itself
  let buildNumber: String?

  private let versionNumberComponents: [Segment]?
  private let buildNumberComponents: [Segment]?
  private let versionNumberSingleNumber: Int?
  private let buildNumberSingleNumber: Int?
  private let hasParsedContent: Bool

  init(versionNumber: String?, buildNumber: String?) {
    self.versionNumber = versionNumber
    self.buildNumber = buildNumber

    let versionNumberComponents = versionNumber?.components(ignoringVersionPrefix: true)
    let buildNumberComponents = buildNumber?.components()
    self.versionNumberComponents = versionNumberComponents
    self.buildNumberComponents = buildNumberComponents
    self.versionNumberSingleNumber = Self.singleNumber(in: versionNumberComponents)
    self.buildNumberSingleNumber = Self.singleNumber(in: buildNumberComponents)
    self.hasParsedContent =
      Self.hasParsedContent(in: versionNumberComponents)
      || Self.hasParsedContent(in: buildNumberComponents)
  }

  /// Flag whether both version number and build number are unavailable
  var isEmpty: Bool {
    !hasParsedContent
  }

  // MARK: - Identity

  static func == (lhs: Version, rhs: Version) -> Bool {
    if lhs.isEmpty && rhs.isEmpty { return true }
    return lhs.versionNumber == rhs.versionNumber && lhs.buildNumber == rhs.buildNumber
  }

  // MARK: - Hashing

  func hash(into hasher: inout Hasher) {
    guard !isEmpty else {
      hasher.combine("Version.empty")
      return
    }

    hasher.combine(versionNumber)
    hasher.combine(buildNumber)
  }

  // MARK: - Update Precedence

  enum UpdateComparison: Sendable {
    case older, newer, samePrecedence, unavailable
  }

  /// Uses this value's build-number fallback rules. The comparison is directional;
  /// it does not define identity or a total order suitable for sorting.
  func comparisonForUpdate(to other: Version) -> UpdateComparison {
    Self.compare(self, other)
  }

  /// Performs the actual check. This version checker is adopted by the Sparkle Framework and slightly adapted.
  private static func compare(_ lhs: Version, _ rhs: Version) -> UpdateComparison {
    if lhs.isEmpty && rhs.isEmpty {
      return .samePrecedence
    }

    var c1: [Segment]?
    var c2: [Segment]?
    var singleNumber1: Int?
    var singleNumber2: Int?

    // Only allow build number checks if build- and version number actually differ
    let allowBuildNumberCheck = lhs.buildNumber != lhs.versionNumber
    if allowBuildNumberCheck, lhs.buildNumber != nil, rhs.buildNumber != nil {
      c1 = lhs.buildNumberComponents
      c2 = rhs.buildNumberComponents
      singleNumber1 = lhs.buildNumberSingleNumber
      singleNumber2 = rhs.buildNumberSingleNumber
    } else {
      c1 = lhs.versionNumberComponents
      c2 = rhs.versionNumberComponents
      singleNumber1 = lhs.versionNumberSingleNumber
      singleNumber2 = rhs.versionNumberSingleNumber
    }

    guard let c1, let c2 else {
      return .unavailable
    }

    if let singleNumber1, let singleNumber2 {
      if singleNumber1 > singleNumber2 {
        return .newer
      } else if singleNumber2 > singleNumber1 {
        return .older
      }

      return .samePrecedence
    }

    let count1 = c1.count
    let count2 = c2.count
    for i in 0..<min(count1, count2) {
      guard case .component(let component1) = c1[i], case .component(let component2) = c2[i] else {
        continue
      }

      let atomsCount1 = component1.count
      let atomsCount2 = component2.count
      for i in 0..<min(atomsCount1, atomsCount2) {
        let component1 = component1[i]
        let component2 = component2[i]

        // Compare numbers
        if case .number(let value1) = component1, case .number(let value2) = component2 {
          if value1 > value2 {
            return .newer  // Think "1.3" vs "1.2"
          } else if value2 > value1 {
            return .older  // Think "1.2" vs "1.3"
          }
        }

        // Compare letters
        else if case .string(let value1) = component1, case .string(let value2) = component2 {
          switch value1.compare(value2) {
          case .orderedAscending:
            return .older  // Think "1.2A" vs "1.2B"
          case .orderedDescending:
            return .newer  // Think "1.2B" vs "1.2A"
          default: ()
          }
        }

        // Not the same type? Now we have to do some validity checking
        else if case .string(_) = component1 {
          return .older  // Think "1.2A" vs "1.2.2"
        }

        else if case .string(_) = component2 {
          return .newer  // Think "1.2.3" vs "1.2A"
        }

        // One is a number and the other is a period. The period is invalid
        else if case .number(_) = component1 {
          return .older  // Think "1.2.." vs "1.2.0"
        }

        else if case .number(_) = component2 {
          return .newer  // Think "1.2.3" vs "1.2.."
        }
      }
      if atomsCount1 != atomsCount2 {
        let leftIsLonger = atomsCount1 > atomsCount2
        let extra = (leftIsLonger ? component1 : component2).dropFirst(
          min(atomsCount1, atomsCount2))
        let comparison = compareExtraAtoms(extra, leftIsLonger: leftIsLonger)
        if comparison != .samePrecedence { return comparison }
      }
    }

    // The versions are equal up to the point where they both still have parts
    // Lets check to see if one is larger than the other
    if count1 != count2 {
      let l = count1 > count2
      let longerComponents = (l ? c1 : c2)[(l ? count2 : count1)...]
      for case .component(let atoms) in longerComponents {
        let comparison = compareExtraAtoms(atoms, leftIsLonger: l)
        if comparison != .samePrecedence { return comparison }
      }
    }

    return .samePrecedence  // Think "1.2" vs "1.2"
  }

  private static func compareExtraAtoms(
    _ atoms: some Sequence<Segment.Atom>, leftIsLonger: Bool
  ) -> UpdateComparison {
    for atom in atoms {
      switch atom {
      case .number(0): continue
      case .number: return leftIsLonger ? .newer : .older
      case .string: return leftIsLonger ? .older : .newer
      }
    }
    return .samePrecedence
  }

  private static func hasParsedContent(in segments: [Segment]?) -> Bool {
    segments?.contains { segment in
      guard case .component(let atoms) = segment else { return false }
      return !atoms.isEmpty
    } ?? false
  }

  private static func singleNumber(in segments: [Segment]?) -> Int? {
    guard let segments, segments.count == 1,
      case .component(let atoms) = segments[0],
      atoms.count == 1,
      case .number(let value) = atoms[0]
    else {
      return nil
    }

    return value
  }
}

extension Version: CustomDebugStringConvertible {
  var debugDescription: String {
    return "Version: \(versionNumber ?? "None"), Build: \(buildNumber ?? "None")"
  }
}

/// An extension helping the version checking
extension String {

  /**
   Returns the components of an version number.
   Components are grouped by Character type, so "12.3" returns [("12", .number), (".", .separator), ("3", .number)]
   */
  fileprivate func components(ignoringVersionPrefix: Bool = false) -> [Version.Segment] {
    let scanner = Scanner(string: self)
    // Appcasts often display "v1.2" while bundle metadata contains "1.2".
    // Ignore that numeric prefix for precedence, retaining the stored display.
    if ignoringVersionPrefix, first == "v" || first == "V", dropFirst().first?.isNumber == true {
      scanner.currentIndex = index(after: startIndex)
    }

    var components = [Version.Segment]()
    var currentAtoms = [Version.Segment.Atom]()

    while !scanner.isAtEnd {
      var number: Int = 0

      // Try to scan number
      if scanner.scanInt(&number) {
        currentAtoms.append(.number(value: number))
      }

      // Try to scan separator
      else if let string = scanner.scanCharacters(from: .separators) {
        components.append(.component(atoms: currentAtoms))
        components.append(.separator(character: string as String))

        currentAtoms.removeAll()
      }

      // Try to scan anything else
      else if let string = scanner.scanCharacters(from: .letters) {
        currentAtoms.append(.string(value: string as String))
      }

      else {
        fatalError("Unable to parse version string: \(self)")
      }
    }

    if !currentAtoms.isEmpty {
      components.append(.component(atoms: currentAtoms))
    }

    return components
  }
}

extension CharacterSet {

  /// Contains all delimiters used by a version string
  fileprivate static let separators = CharacterSet.whitespacesAndNewlines.union(
    .punctuationCharacters)

  /// Contains any characters but separators and digits
  fileprivate static let letters = CharacterSet.separators.union(.decimalDigits).inverted

}

// Defining the type of a character
extension Version {
  fileprivate enum Segment: Equatable, Sendable {

    enum Atom: Equatable, Sendable {
      case number(value: Int)  // 0..9
      case string(value: String)  // Everything else

    }

    case separator(character: String)  // Newlines, punctuation..
    case component(atoms: [Atom])  // [123, A]

    var plainComponent: String? {
      guard case .component(let atoms) = self else {
        return nil
      }

      return atoms.map { atom in
        switch atom {
        case .number(let value):
          return "\(value)"
        case .string(let value):
          return value
        }
      }.joined()
    }

  }

}

extension Array where Element == Version.Segment {
  func joined() -> String? {
    let string = self.map { segment in
      switch segment {
      case .separator(let character):
        character
      case .component(_):
        segment.plainComponent!
      }
    }.joined()

    return string.isEmpty ? nil : string
  }
}

// MARK: - Version Sanitization

extension Version {

  func sanitize(with appVersion: Version) -> Version {
    // The last component of the version number is actually the build number. (Can only be detected for equal build numbers. Avoids false positives)
    // App: 1.2 (40)
    // Remote: 1.2.40
    if buildNumber == nil, var components = versionNumberComponents,
      let lastRemoteComponent = components.last?.plainComponent,
      lastRemoteComponent == appVersion.buildNumber
    {
      // Remove build number segment from version number and store it separately.
      let buildNumber = components.removeLast()

      // Remove separator as well.
      if !components.isEmpty {
        components.removeLast()
      }

      return Version(versionNumber: components.joined(), buildNumber: buildNumber.plainComponent)
    }

    // The entire version number equals the app versions build number. We assume version number by default, but that may not be the case.
    if let versionNumber, versionNumber == appVersion.buildNumber {
      // Switch to build number.
      return Version(versionNumber: nil, buildNumber: versionNumber)
    }

    //
    if appVersion.buildNumber == appVersion.versionNumber, var components = versionNumberComponents,
      components.last?.plainComponent != nil, components.count == 7
    {
      components.removeLast()
      components.removeLast()

      if components.joined() == appVersion.buildNumber {
        return Version(versionNumber: components.joined(), buildNumber: buildNumber)
      }
    }

    // Nothing changed
    return self
  }

}

// MARK: -

extension OperatingSystemVersion {

  init(string: String) throws {
    let components = string.components().flatMap({ component in
      switch component {
      case .component(let atoms):
        return atoms.compactMap { atom in
          switch atom {
          case .number(let value):
            return value
          default:
            return nil
          }
        }
      default:
        return []
      }
    })
    guard !components.isEmpty else {
      throw OperatingSystemVersionError.parsingError(version: string)
    }

    let major = components[0]
    let minor = components.count > 1 ? components[1] : 0
    let patch = components.count > 2 ? components[2] : 0
    self.init(majorVersion: major, minorVersion: minor, patchVersion: patch)
  }

  enum OperatingSystemVersionError: Error {
    case parsingError(version: String)
  }

}
