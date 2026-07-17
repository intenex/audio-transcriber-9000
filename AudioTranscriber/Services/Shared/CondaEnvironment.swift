import Foundation

/// Shared conda + script path resolution for the local mlx-lm chat subprocess.
/// (Local transcription no longer uses Python; only chat does.)
enum CondaEnvironment {
    static let envName = "transcriber"

    /// Locate the conda binary. GUI apps don't inherit shell PATH, so probe
    /// well-known install locations. Returns nil when conda isn't installed —
    /// callers must treat that as "local LLM unavailable", never shell out to `env`.
    static func resolveCondaPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/miniconda3/condabin/conda",
            "\(home)/miniconda3/bin/conda",
            "\(home)/anaconda3/condabin/conda",
            "\(home)/anaconda3/bin/conda",
            "/opt/homebrew/Caskroom/miniconda/base/condabin/conda",
            "/opt/miniconda3/condabin/conda",
            "/usr/local/miniconda3/condabin/conda",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Locate a script from the app bundle's Resources/scripts, walking up from
    /// the bundle for dev builds, with a repo-relative dev fallback.
    static func resolveScript(named name: String) -> String? {
        let fm = FileManager.default

        // Bundled (release) location
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("scripts/\(name)")
            if fm.fileExists(atPath: bundled) { return bundled }
        }

        // Walk up from the bundle looking for a scripts/ dir (dev builds in DerivedData won't hit this,
        // but builds run from the repo will)
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("scripts/\(name)").path
            if fm.fileExists(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }

        // Dev fallback: repo location
        let dev = "\(NSHomeDirectory())/Dropbox/code/audio-transcriber/scripts/\(name)"
        if fm.fileExists(atPath: dev) { return dev }

        return nil
    }
}
