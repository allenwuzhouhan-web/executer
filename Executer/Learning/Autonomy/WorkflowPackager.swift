import Foundation
import AppKit
import CryptoKit

/// Packages, exports, and imports generalized workflows as portable .execflow files.
///
/// Phase 15 of the Workflow Recorder ("The Envoy").
///
/// Export: workflow → privacy redaction → JSON manifest → digital signature → .execflow
/// Import: .execflow → signature verify → compatibility check → security assess → parameter map
enum WorkflowPackager {

    /// File extension for packaged workflows.
    static let fileExtension = "execflow"

    // MARK: - Export

    /// Export a workflow as a portable .execflow package.
    /// Strips all personal data while preserving workflow structure.
    static func export(_ workflow: GeneralizedWorkflow) throws -> ExecFlowPackage {
        // 1. Redact personal data
        let redacted = PrivacyRedactor.redact(workflow)

        // 2. Build manifest
        let manifest = PackageManifest(
            version: 1,
            createdAt: Date(),
            creatorId: nil,  // Anonymous by default
            executableVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            requiredApps: redacted.applicability.requiredApps,
            category: redacted.category,
            stepCount: redacted.steps.count,
            parameterCount: redacted.parameters.count
        )

        // 3. Encode workflow
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let workflowData = try encoder.encode(redacted)
        let manifestData = try encoder.encode(manifest)

        // 4. Compute signature (SHA256 of workflow JSON)
        let hash = SHA256.hash(data: workflowData)
        let signature = hash.map { String(format: "%02x", $0) }.joined()

        return ExecFlowPackage(
            manifest: manifest,
            workflow: redacted,
            workflowJSON: String(data: workflowData, encoding: .utf8) ?? "{}",
            manifestJSON: String(data: manifestData, encoding: .utf8) ?? "{}",
            signature: signature
        )
    }

    /// Write an .execflow package to disk.
    static func writeToDisk(_ package: ExecFlowPackage, directory: URL) throws -> URL {
        let safeName = package.workflow.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .prefix(50)
        let filename = "\(safeName).\(fileExtension)"
        let fileURL = directory.appendingPathComponent(String(filename))

        // Bundle as a single JSON file containing manifest + workflow + signature
        let bundle = ExecFlowBundle(
            manifest: package.manifestJSON,
            workflow: package.workflowJSON,
            signature: package.signature
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(bundle)
        try data.write(to: fileURL)

        return fileURL
    }

    // MARK: - Import

    /// Import a workflow from an .execflow file.
    static func importFromDisk(_ fileURL: URL) throws -> ImportResult {
        let data = try Data(contentsOf: fileURL)
        return try importFromData(data)
    }

    /// Import from raw data.
    static func importFromData(_ data: Data) throws -> ImportResult {
        let decoder = JSONDecoder()
        let bundle = try decoder.decode(ExecFlowBundle.self, from: data)

        // 1. Parse workflow
        guard let workflowData = bundle.workflow.data(using: .utf8) else {
            return ImportResult(status: .failed, workflow: nil, warnings: ["Invalid workflow data"])
        }
        let workflow = try decoder.decode(GeneralizedWorkflow.self, from: workflowData)

        // 2. Verify signature
        let computedHash = SHA256.hash(data: workflowData)
        let computedSignature = computedHash.map { String(format: "%02x", $0) }.joined()
        let signatureValid = computedSignature == bundle.signature

        // 3. Check compatibility
        let compatibility = CompatibilityChecker.check(workflow)

        // 4. Security assessment
        let security = SecurityAssessor.assess(workflow)

        var warnings: [String] = []
        if !signatureValid { warnings.append("Signature mismatch — package may have been modified") }
        warnings.append(contentsOf: compatibility.warnings)
        warnings.append(contentsOf: security.warnings)

        let status: ImportStatus
        if security.riskLevel == .dangerous {
            status = .rejected
        } else if !compatibility.isCompatible {
            status = .incompatible
        } else {
            status = signatureValid ? .ready : .readyWithWarnings
        }

        return ImportResult(
            status: status,
            workflow: workflow,
            warnings: warnings
        )
    }
}

// MARK: - Privacy Redactor

/// Strips personal data from workflows before export.
/// Preserves structure, removes concrete values.
enum PrivacyRedactor {

    /// Patterns to redact from text fields.
    private static let redactionPatterns: [(pattern: String, replacement: String)] = [
        (#"/Users/[^/\s]+"#, "/Users/[user]"),              // Home directory paths
        (#"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, "[email]"),  // Email addresses
        (#"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#, "[phone]"),     // Phone numbers
        (#"https?://[^\s\"]+"#, "[url]"),                     // URLs
    ]

    static func redact(_ workflow: GeneralizedWorkflow) -> GeneralizedWorkflow {
        var redacted = workflow

        // Redact step descriptions and targets
        redacted.steps = workflow.steps.map { step in
            AbstractStep(
                operation: step.operation,
                target: ElementTarget(
                    role: step.target.role,
                    label: redactText(step.target.label),
                    elementType: step.target.elementType,
                    positionalHint: step.target.positionalHint
                ),
                appContext: step.appContext,  // App names are kept — they're public
                parameterBindings: step.parameterBindings.mapValues { redactText($0) },
                precondition: step.precondition,
                description: redactText(step.description)
            )
        }

        // Redact parameter defaults and examples
        redacted.parameters = workflow.parameters.map { param in
            WorkflowParameter(
                name: param.name,
                type: param.type,
                description: param.description,
                defaultValue: nil,  // Strip defaults
                exampleValues: [],  // Strip examples
                stepBindings: param.stepBindings
            )
        }

        // Clear source journal reference
        redacted.sourceJournalId = nil

        return redacted
    }

    private static func redactText(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in redactionPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }
        return result
    }
}

// MARK: - Compatibility Checker

enum CompatibilityChecker {
    struct Result {
        let isCompatible: Bool
        let missingApps: [String]
        let warnings: [String]
    }

    static func check(_ workflow: GeneralizedWorkflow) -> Result {
        let runningApps = NSWorkspace.shared.runningApplications
            .compactMap(\.localizedName)
            .map { $0.lowercased() }

        let installedAppPaths = ["/Applications", "/System/Applications"]
        var installedApps: Set<String> = Set(runningApps)
        for dir in installedAppPaths {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for app in contents where app.hasSuffix(".app") {
                    installedApps.insert(app.replacingOccurrences(of: ".app", with: "").lowercased())
                }
            }
        }

        let required = workflow.applicability.requiredApps
        let missing = required.filter { app in
            !installedApps.contains(app.lowercased())
        }

        var warnings: [String] = []
        if !missing.isEmpty {
            warnings.append("Missing apps: \(missing.joined(separator: ", "))")
        }

        return Result(
            isCompatible: missing.isEmpty,
            missingApps: missing,
            warnings: warnings
        )
    }
}

// MARK: - Security Assessor

enum SecurityAssessor {
    enum RiskLevel: String { case safe, caution, dangerous }

    struct Result {
        let riskLevel: RiskLevel
        let warnings: [String]
    }

    static func assess(_ workflow: GeneralizedWorkflow) -> Result {
        var warnings: [String] = []
        var maxRisk: RiskLevel = .safe

        for step in workflow.steps {
            // Check for dangerous operations
            switch step.operation {
            case .deleteFile:
                warnings.append("Workflow includes file deletion")
                maxRisk = .caution
            case .quitApp:
                if step.appContext.lowercased().contains("finder") {
                    warnings.append("Workflow quits Finder — may disrupt system")
                    maxRisk = .caution
                }
            case .fillField:
                // Check for potential credential injection
                if step.target.role.lowercased().contains("password") {
                    warnings.append("Workflow interacts with password fields")
                    maxRisk = .dangerous
                }
            default:
                break
            }
        }

        return Result(riskLevel: maxRisk, warnings: warnings)
    }
}

// MARK: - Package Models

struct ExecFlowPackage: Sendable {
    let manifest: PackageManifest
    let workflow: GeneralizedWorkflow
    let workflowJSON: String
    let manifestJSON: String
    let signature: String
}

struct ExecFlowBundle: Codable {
    let manifest: String       // JSON string
    let workflow: String       // JSON string
    let signature: String      // SHA256 hex
}

struct PackageManifest: Codable, Sendable {
    let version: Int
    let createdAt: Date
    let creatorId: String?
    let executableVersion: String
    let requiredApps: [String]
    let category: String
    let stepCount: Int
    let parameterCount: Int
}

enum ImportStatus: String, Sendable {
    case ready                  // Good to import
    case readyWithWarnings      // Importable but with caveats
    case incompatible           // Missing required apps
    case rejected               // Security risk too high
    case failed                 // Parse error
}

struct ImportResult: Sendable {
    let status: ImportStatus
    let workflow: GeneralizedWorkflow?
    let warnings: [String]
}
