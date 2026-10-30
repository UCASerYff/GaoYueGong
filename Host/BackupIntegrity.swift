import Foundation
import CryptoKit
#if canImport(Monthly)
import Monthly
#endif

enum BackupPreferenceDomain: String, CaseIterable { case standard, module }
protocol BackupPreferenceAccess {
    func read(_ domain: BackupPreferenceDomain) throws -> [String:Any]?
    func write(_ values: [String:Any]?, to domain: BackupPreferenceDomain) throws
}
private struct LiveBackupPreferences: BackupPreferenceAccess {
    private func name(_ domain: BackupPreferenceDomain) throws -> String {
        if domain == .module { return "com.gaoseries.GaoYueGong.Monthly" }
        guard let identifier=Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }
        return identifier
    }
    func read(_ domain: BackupPreferenceDomain) throws -> [String:Any]? {
        UserDefaults.standard.persistentDomain(forName:try name(domain))
    }
    func write(_ values: [String:Any]?, to domain: BackupPreferenceDomain) throws {
        let name=try name(domain)
        if let values { UserDefaults.standard.setPersistentDomain(values,forName:name) }
        else { UserDefaults.standard.removePersistentDomain(forName:name) }
        guard UserDefaults.standard.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Streaming checksums keep large PDFs and Word attachments out of resident memory.
enum BackupIntegrity {
    struct Manifest: Codable { var appID="com.gaoseries.GaoYueGong"; var format=1; var version:String; var createdAt=Date(); var files:[String:String] }
    /// nil preserves an absent persistent domain; Data can also represent a present empty dictionary.
    struct PreferenceSnapshot: Codable { var standard:Data?; var module:Data? }
    static var preferences: any BackupPreferenceAccess = LiveBackupPreferences()
    private static func encodeDomain(_ values:[String:Any]?) throws -> Data? {
        try values.map { try PropertyListSerialization.data(fromPropertyList:$0,format:.binary,options:0) }
    }
    private static func decodeDomain(_ data:Data?) throws -> [String:Any]? {
        guard let data else { return nil }
        guard let values=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        return values
    }
    static func capturePreferences() throws -> PreferenceSnapshot {
        try PreferenceSnapshot(standard:encodeDomain(preferences.read(.standard)),module:encodeDomain(preferences.read(.module)))
    }
    static func validatePreferencesSnapshot(_ snapshot:PreferenceSnapshot) throws {
        _ = try decodeDomain(snapshot.standard); _ = try decodeDomain(snapshot.module)
    }
    static func restorePreferences(_ snapshot:PreferenceSnapshot) throws {
        let standard=try decodeDomain(snapshot.standard), module=try decodeDomain(snapshot.module)
        try preferences.write(standard,to:.standard)
        try preferences.write(module,to:.module)
        try verifyPreferences(snapshot)
    }
    static func verifyPreferences(_ snapshot:PreferenceSnapshot) throws {
        for (domain,data) in [(BackupPreferenceDomain.standard,snapshot.standard),(.module,snapshot.module)] {
            let expected=try decodeDomain(data), actual=try preferences.read(domain)
            guard (expected == nil && actual == nil)
                || (expected != nil && actual != nil && NSDictionary(dictionary:expected!).isEqual(to:actual!))
            else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    static func archivedPreferences(_ root:URL, expectedHash:String? = nil) throws -> PreferenceSnapshot {
        let data=try Data(contentsOf:root.appendingPathComponent("preferences.plist"))
        if let expectedHash {
            guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == expectedHash else { throw CocoaError(.fileReadCorruptFile) }
        }
        guard let values=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any],
              Set(values.keys) == Set(["standard","module"]),
              let standard=values["standard"] as? [String:Any],let module=values["module"] as? [String:Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        return try PreferenceSnapshot(standard:encodeDomain(standard),module:encodeDomain(module))
    }
    static func hash(_ file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file);defer { try? handle.close() }
        var digest=SHA256()
        while let data=try handle.read(upToCount:1_048_576),!data.isEmpty { digest.update(data:data) }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func files(_ root:URL) throws -> [URL] {
        let root=root.resolvingSymlinksInPath()
        let fm=FileManager.default
        var traversalError:Error?
        guard let e=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],errorHandler:{ _,error in
            traversalError=error;return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var result:[URL]=[]
        for case let file as URL in e {
            let v=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard v.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if v.isRegularFile == true { result.append(file.resolvingSymlinksInPath()) }
        }
        if let traversalError { throw traversalError }
        return result
    }
    static func manifest(_ root:URL) throws -> [String:String] {
        let root=root.resolvingSymlinksInPath()
        var result:[String:String]=[:]
        for file in try files(root) where file.path != root.appendingPathComponent("gqns-manifest.json").path {
            result[String(file.path.dropFirst(root.path.count+1))]=try hash(file)
        }
        return result
    }
    static func verify(_ root:URL) throws -> Manifest {
        let m=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("gqns-manifest.json")))
        let actual=try manifest(root)
        guard m.appID == "com.gaoseries.GaoYueGong",m.format == 1,!m.files.isEmpty,actual==m.files else {
            let differences=Set(actual.keys).union(m.files.keys).filter { actual[$0] != m.files[$0] }.sorted().prefix(5).joined(separator:", ")
            throw NSError(domain:"GQNS.Backup",code:1,userInfo:[NSLocalizedDescriptionKey:"备份文件校验不一致："+differences])
        }
        let current=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "3.63"
        guard m.version.range(of:"^[0-9]+(?:\\.[0-9]+)*$",options:.regularExpression) != nil,
              m.version.compare(current,options:.numeric) != .orderedDescending,
              m.files["preferences.plist"] != nil,
              m.files["AppGroupContainer/Monthly/monthly.sqlite"] != nil,
              m.files.keys.allSatisfy({ $0 == "preferences.plist" || $0.hasPrefix("ApplicationSupport-Monthly/") || $0.hasPrefix("AppGroupContainer/") })
        else { throw CocoaError(.fileReadCorruptFile) }
        for name in ["ApplicationSupport-Monthly","AppGroupContainer"] {
            let values=try root.appendingPathComponent(name).resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isDirectory == true,values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        }
        _ = try archivedPreferences(root,expectedHash:m.files["preferences.plist"])
        for file in try files(root) where file.pathExtension == "sqlite" {
            guard DailyBackup.integrityCheck(file)=="ok" else { throw CocoaError(.fileReadCorruptFile) }
        }
        try MonthlyArchiveValidation.validateStore(at:root.appendingPathComponent("AppGroupContainer/Monthly"))
        return m
    }
    /// Verify the files actually copied into the live destinations before changing preferences.
    static func verifyInstalled(_ manifest:Manifest,app:URL,group:URL) throws {
        var actual:[String:String]=[:]
        for (prefix,root) in [("ApplicationSupport-Monthly/",app),("AppGroupContainer/",group)] {
            let normalized=root.resolvingSymlinksInPath()
            for file in try files(root) {
                let relative=String(file.path.dropFirst(normalized.path.count+1))
                if prefix == "AppGroupContainer/", relative.hasPrefix(".com.apple.") { continue }
                actual[prefix+relative]=try hash(file)
            }
        }
        guard actual == manifest.files.filter({$0.key != "preferences.plist"}) else { throw CocoaError(.fileReadCorruptFile) }
        try MonthlyArchiveValidation.validateStore(at:group.appendingPathComponent("Monthly"))
    }
    static func verifyCopy(from source:URL,to target:URL) throws {
        let sourceValues=try source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        let targetValues=try target.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard sourceValues.isSymbolicLink != true,targetValues.isSymbolicLink != true,
              sourceValues.isDirectory == targetValues.isDirectory else { throw CocoaError(.fileReadCorruptFile) }
        if sourceValues.isDirectory == true {
            func contents(_ root:URL) throws -> [String:String] {
                let normalized=root.resolvingSymlinksInPath()
                return try Dictionary(uniqueKeysWithValues:files(root).map { (String($0.path.dropFirst(normalized.path.count+1)),try hash($0)) })
            }
            guard try contents(source) == contents(target) else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            guard try hash(source) == hash(target) else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
    static func copySnapshot(from source:URL,to target:URL) throws {
        let source=source.resolvingSymlinksInPath()
        let fm=FileManager.default
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        for file in try files(source) {
            let relative=String(file.path.dropFirst(source.path.count+1))
            // Container metadata belongs to macOS; journals are folded into SQLite snapshots.
            if relative.hasPrefix(".com.apple.") || file.lastPathComponent.hasSuffix("-wal") || file.lastPathComponent.hasSuffix("-shm") { continue }
            let dest=target.appendingPathComponent(relative)
            try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true)
            if file.pathExtension == "sqlite" {
                try DailyBackup.vacuumInto(source:file,destination:dest)
                guard DailyBackup.integrityCheck(dest)=="ok" else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                // Atomic writers are safe; concurrent non-atomic attachment changes are detected.
                try fm.copyItem(at:file,to:dest)
                guard try hash(file)==hash(dest) else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }
}
