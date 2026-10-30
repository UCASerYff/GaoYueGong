import Foundation

/// Host backup validation shares the exact store/schema checks used by the app and widgets.
public enum MonthlyArchiveValidation {
  public static func validateStore(at directoryURL: URL) throws {
    _ = try Database(directory: directoryURL, readOnly: true).readRecord()
  }
}
