import Foundation

enum ProductBuild {
    static let marketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    static let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    static let displayVersion = "\(marketingVersion) (\(buildNumber))"
}
