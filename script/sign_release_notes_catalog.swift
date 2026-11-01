#!/usr/bin/env swift  //  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-08.  //  Licensed under GPL-3.0; see LICENSE.md.
import CryptoKit
import Foundation

private struct SignedEnvelope: Codable {
  let schemaVersion: Int
  let payload: Data
  let signature: Data
}

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
  exit(2)
}

guard CommandLine.arguments.count == 3 else {
  fail(
    "usage: LATEST_RELEASE_NOTES_CATALOG_PRIVATE_KEY=<base64> script/sign_release_notes_catalog.swift INPUT_JSON OUTPUT_JSON"
  )
}

guard
  let encodedPrivateKey = ProcessInfo.processInfo.environment[
    "LATEST_RELEASE_NOTES_CATALOG_PRIVATE_KEY"],
  let privateKeyData = Data(base64Encoded: encodedPrivateKey)
else {
  fail(
    "LATEST_RELEASE_NOTES_CATALOG_PRIVATE_KEY must contain a base64-encoded Curve25519 signing private key"
  )
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

do {
  let payload = try Data(contentsOf: inputURL)
  let json = try JSONSerialization.jsonObject(with: payload)
  guard let definitions = json as? [[String: Any]], !definitions.isEmpty else {
    fail("input must be a non-empty release-notes definition array")
  }

  let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
  let signature = try privateKey.signature(for: payload)
  guard privateKey.publicKey.isValidSignature(signature, for: payload) else {
    fail("generated signature did not verify")
  }

  let envelope = SignedEnvelope(schemaVersion: 1, payload: payload, signature: signature)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  var encodedEnvelope = try encoder.encode(envelope)
  encodedEnvelope.append(0x0A)
  try encodedEnvelope.write(to: outputURL, options: .atomic)

  print(
    "SIGNED RELEASE NOTES CATALOG definitions=\(definitions.count) bytes=\(encodedEnvelope.count)")
  print(
    "LATEST_RELEASE_NOTES_CATALOG_PUBLIC_KEY=\(privateKey.publicKey.rawRepresentation.base64EncodedString())"
  )
} catch {
  fail(error.localizedDescription)
}
