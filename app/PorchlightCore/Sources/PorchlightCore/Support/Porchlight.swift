import Foundation

public enum Porchlight {
    /// The app's version, from its bundle. Builds without one (the CLI, tests) are "dev".
    public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
