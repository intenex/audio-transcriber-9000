import Foundation

// Sheet-item plumbing shared by both platforms' views. These retroactive
// conformances must exist exactly once per module — keep them here, never in
// a platform-specific file.

/// Allow String to drive .sheet(item:) (category renames etc.).
extension String: @retroactive Identifiable {
    public var id: String { self }
}

/// Allow UUID to drive .sheet(item:).
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
