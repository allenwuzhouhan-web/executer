import Foundation

/// Specification for content to be created by the Content Factory.
struct ContentSpec: Codable, Sendable {
    let outputType: OutputType
    let topic: String
    let format: String?
    let audience: String?
    let sourceMaterials: [String]?  // File paths or URLs to draw from
    let outputPath: String?         // Where to save the result

    enum OutputType: String, Codable, Sendable {
        case presentation
        case document
        case spreadsheet
        case summary
        case research
        case script
    }
}
