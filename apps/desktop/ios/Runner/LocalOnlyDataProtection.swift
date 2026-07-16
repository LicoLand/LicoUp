import Foundation

/// Owns the local-only Application Support boundary for Flutter and native code.
/// The root exclusion remains effective for atomic descendants; native writers
/// additionally reapply and verify the item flag after every replacement.
enum LocalOnlyDataProtection {
  static let productDirectoryName = "LicoArc"
  static let portableDataDirectoryName = "portable-data"
  static let secureMeshDirectoryName = "secure-mesh"

  static func prepareApplicationSupportRoots(
    fileManager: FileManager = .default
  ) throws -> URL {
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    _ = try excludeObsoletePortableDataRootFromBackup(
      applicationSupportRoot: base,
      fileManager: fileManager
    )
    let productRoot = base.appendingPathComponent(productDirectoryName, isDirectory: true)
    try createProtectedDirectory(productRoot, fileManager: fileManager)
    try createProtectedDirectory(
      productRoot.appendingPathComponent(portableDataDirectoryName, isDirectory: true),
      fileManager: fileManager
    )
    try createProtectedDirectory(
      productRoot.appendingPathComponent(secureMeshDirectoryName, isDirectory: true),
      fileManager: fileManager
    )
    try hardenTree(productRoot, fileManager: fileManager)
    return productRoot
  }

  /// Repairs only the backup eligibility of the formerly unscoped data root.
  /// The directory is never enumerated, read, copied, renamed, or imported.
  @discardableResult
  static func excludeObsoletePortableDataRootFromBackup(
    applicationSupportRoot: URL,
    fileManager: FileManager = .default
  ) throws -> Bool {
    let base = applicationSupportRoot.standardizedFileURL
    let obsoleteRoot = base
      .appendingPathComponent(portableDataDirectoryName, isDirectory: true)
      .standardizedFileURL
    guard obsoleteRoot.deletingLastPathComponent() == base else {
      throw CocoaError(.fileWriteNoPermission)
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: obsoleteRoot.path, isDirectory: &isDirectory) else {
      return false
    }
    guard isDirectory.boolValue else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let values = try obsoleteRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    try applyProtection(obsoleteRoot, fileManager: fileManager)
    return true
  }

  static func portableDataRoot(fileManager: FileManager = .default) throws -> URL {
    try prepareApplicationSupportRoots(fileManager: fileManager)
      .appendingPathComponent(portableDataDirectoryName, isDirectory: true)
  }

  static func secureMeshRoot(fileManager: FileManager = .default) throws -> URL {
    try prepareApplicationSupportRoots(fileManager: fileManager)
      .appendingPathComponent(secureMeshDirectoryName, isDirectory: true)
  }

  static func protectLocalItem(
    _ item: URL,
    under productRoot: URL,
    fileManager: FileManager = .default
  ) throws {
    let rootPath = productRoot.standardizedFileURL.path
    let itemPath = item.standardizedFileURL.path
    guard itemPath == rootPath || itemPath.hasPrefix(rootPath + "/") else {
      throw CocoaError(.fileWriteNoPermission)
    }
    let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    try applyProtection(item, fileManager: fileManager)
  }

  static func hardenTree(
    _ productRoot: URL,
    fileManager: FileManager = .default
  ) throws {
    try protectLocalItem(productRoot, under: productRoot, fileManager: fileManager)
    guard let enumerator = fileManager.enumerator(
      at: productRoot,
      includingPropertiesForKeys: [.isSymbolicLinkKey],
      options: []
    ) else {
      throw CocoaError(.fileReadUnknown)
    }
    for case let item as URL in enumerator {
      try protectLocalItem(item, under: productRoot, fileManager: fileManager)
    }
  }

  static func isExcludedFromBackup(_ item: URL) throws -> Bool {
    try item.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
  }

  private static func createProtectedDirectory(
    _ directory: URL,
    fileManager: FileManager
  ) throws {
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    )
    try applyProtection(directory, fileManager: fileManager)
  }

  private static func applyProtection(_ item: URL, fileManager: FileManager) throws {
    try fileManager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: item.path
    )
    var mutableItem = item
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutableItem.setResourceValues(values)
    guard try isExcludedFromBackup(item) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
