import Foundation

/// Tool: create_3d_model — Creates 3D models using Blender's Python API in headless mode.
struct CreateBlenderModelTool: ToolDefinition {
    let name = "create_3d_model"
    let description = """
        Create a 3D model (.glb, .obj, .fbx, .stl) using Blender's Python API. \
        Requires Blender installed on the system.

        ## CRITICAL: EXECUTE IMMEDIATELY.
        Do NOT describe the model in text. Generate the full JSON spec with bpy_code and call this tool RIGHT NOW.

        ## HOW IT WORKS:
        You write Python code using Blender's bpy/bmesh API. The engine handles scene setup, \
        material creation, validation, and export automatically. Your code just creates geometry.

        ## SPEC FORMAT:
        {
          "filename": "model_name.glb",
          "bpy_code": "# Your geometry code here using bpy, bmesh, Vector, Matrix, math\\n...",
          "materials": [
            {"name": "Steel", "base_color": [0.7, 0.7, 0.75, 1.0], "roughness": 0.3, "metallic": 1.0}
          ],
          "export_format": "glb",
          "validation": {"ensure_manifold": true, "ensure_normals": true}
        }

        ## AVAILABLE IN bpy_code NAMESPACE:
        - bpy, bmesh, mathutils, Vector, Matrix, Euler, Quaternion, Color, math
        - create_material(name, base_color=[r,g,b,a], roughness=0.5, metallic=0.0, \
          emission_color=None, emission_strength=0.0, alpha=1.0, specular=0.5)
        - assign_material(obj, mat)

        ## GEOMETRY CREATION PATTERNS:

        ### Primitives:
        bpy.ops.mesh.primitive_cube_add(size=2, location=(0,0,0))
        bpy.ops.mesh.primitive_uv_sphere_add(radius=1, segments=32, ring_count=16)
        bpy.ops.mesh.primitive_cylinder_add(radius=1, depth=2, vertices=32)
        bpy.ops.mesh.primitive_cone_add(radius1=1, radius2=0, depth=2, vertices=32)
        bpy.ops.mesh.primitive_torus_add(major_radius=1, minor_radius=0.25)
        bpy.ops.mesh.primitive_plane_add(size=2)
        bpy.ops.mesh.primitive_ico_sphere_add(radius=1, subdivisions=3)

        ### Modifiers:
        obj = bpy.context.active_object
        mod = obj.modifiers.new("Subsurf", 'SUBSURF')
        mod.levels = 2
        bpy.ops.object.modifier_apply(modifier="Subsurf")

        mod = obj.modifiers.new("Bevel", 'BEVEL')
        mod.width = 0.05
        mod.segments = 3
        bpy.ops.object.modifier_apply(modifier="Bevel")

        mod = obj.modifiers.new("Mirror", 'MIRROR')
        mod.use_axis = (True, False, False)
        bpy.ops.object.modifier_apply(modifier="Mirror")

        mod = obj.modifiers.new("Solidify", 'SOLIDIFY')
        mod.thickness = 0.1
        bpy.ops.object.modifier_apply(modifier="Solidify")

        ### BMesh (advanced geometry):
        bm = bmesh.new()
        v1 = bm.verts.new((0, 0, 0))
        v2 = bm.verts.new((1, 0, 0))
        v3 = bm.verts.new((0.5, 1, 0))
        bm.faces.new((v1, v2, v3))
        mesh = bpy.data.meshes.new("CustomMesh")
        bm.to_mesh(mesh)
        bm.free()
        obj = bpy.data.objects.new("CustomObject", mesh)
        bpy.context.collection.objects.link(obj)

        ### Materials in bpy_code:
        mat = create_material("Gold", base_color=[1.0, 0.84, 0.0, 1.0], metallic=1.0, roughness=0.2)
        assign_material(bpy.context.active_object, mat)

        ## EXPORT FORMATS: glb (default, recommended), gltf, obj, fbx, stl

        ## QUALITY RULES:
        1. Always use enough vertices for smooth curves (segments=32+ for cylinders/spheres)
        2. Apply subdivision surface for organic shapes
        3. Use bevel modifier on hard edges for realism
        4. Keep geometry manifold (watertight) — no holes, no interior faces
        5. Assign materials to all objects

        ## EXAMPLE — Chess pawn:
        {
          "filename": "chess_pawn.glb",
          "bpy_code": "import bpy\\nimport bmesh\\nfrom mathutils import Vector\\n\\n# Base\\nbpy.ops.mesh.primitive_cylinder_add(radius=0.5, depth=0.15, vertices=32, location=(0,0,0.075))\\nbase = bpy.context.active_object\\nbase.name = 'Base'\\nmod = base.modifiers.new('Bevel', 'BEVEL')\\nmod.width = 0.02\\nmod.segments = 3\\nbpy.ops.object.modifier_apply(modifier='Bevel')\\n\\n# Body\\nbpy.ops.mesh.primitive_cylinder_add(radius=0.3, depth=0.6, vertices=32, location=(0,0,0.45))\\nbody = bpy.context.active_object\\nbody.name = 'Body'\\nmod = body.modifiers.new('Bevel', 'BEVEL')\\nmod.width = 0.02\\nmod.segments = 2\\nbpy.ops.object.modifier_apply(modifier='Bevel')\\n\\n# Head sphere\\nbpy.ops.mesh.primitive_uv_sphere_add(radius=0.22, segments=32, ring_count=16, location=(0,0,0.9))\\nhead = bpy.context.active_object\\nhead.name = 'Head'\\n\\n# Neck ring\\nbpy.ops.mesh.primitive_torus_add(major_radius=0.25, minor_radius=0.04, location=(0,0,0.72))\\nneck = bpy.context.active_object\\nneck.name = 'Neck'\\n\\n# Apply ivory material to all\\nmat = create_material('Ivory', base_color=[0.95, 0.93, 0.88, 1.0], roughness=0.4, metallic=0.0)\\nfor obj in bpy.data.objects:\\n    if obj.type == 'MESH':\\n        assign_material(obj, mat)",
          "export_format": "glb"
        }
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "spec": JSONSchema.string(description: """
                JSON spec with bpy_code for geometry creation. Must include 'bpy_code' field. \
                Optional: 'filename', 'materials' array, 'export_format' (glb/obj/fbx/stl), \
                'validation' settings.
                """),
            "output_dir": JSONSchema.string(description: "Directory to save the file. Default: ~/Desktop"),
        ], required: ["spec"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let specJSON = try requiredString("spec", from: args)
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath

        // Validate spec JSON
        guard let specData = specJSON.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            return "Error: Invalid spec JSON. Must be a JSON object with a 'bpy_code' field."
        }

        guard spec["bpy_code"] is String else {
            return "Error: Spec must contain a 'bpy_code' string with Blender Python geometry code."
        }

        // Find Blender
        guard let blender = BlenderExecutor.findBlender() else {
            return "Error: Blender is not installed. Install from https://www.blender.org/download/ or run: brew install --cask blender"
        }

        // Determine output path
        let exportFormat = (spec["export_format"] as? String) ?? "glb"
        let filename = (spec["filename"] as? String) ?? "model.\(exportFormat)"
        let outputPath = (expandedDir as NSString).appendingPathComponent(filename)

        // Ensure engine script is in App Support
        let appSupport = URL.applicationSupportDirectory
        let execDir = appSupport.appendingPathComponent("Executer")
        BlenderExecutor.ensureResource("blender_engine", ext: "py", in: execDir)
        let enginePath = execDir.appendingPathComponent("blender_engine.py")

        guard FileManager.default.fileExists(atPath: enginePath.path) else {
            return "Error: blender_engine.py not found. Reinstall the app."
        }

        // Write spec to temp file
        let tempSpec = FileManager.default.temporaryDirectory
            .appendingPathComponent("blender_spec_\(UUID().uuidString).json")
        try specJSON.write(to: tempSpec, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempSpec) }

        // Create output directory if needed
        try? FileManager.default.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)

        // Run Blender headless
        let result = try await BlenderExecutor.runBlender(
            blender: blender,
            script: enginePath.path,
            args: ["--spec", tempSpec.path, "--output", outputPath],
            timeoutSeconds: 120
        )

        // Parse result
        if let resultData = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
           let success = json["success"] as? Bool {
            if success {
                let path = json["path"] as? String ?? outputPath
                let stats = json["stats"] as? [String: Any] ?? [:]
                let verts = stats["vertices"] as? Int ?? 0
                let faces = stats["faces"] as? Int ?? 0
                let sizeBytes = stats["file_size_bytes"] as? Int ?? 0
                let sizeKB = sizeBytes / 1024
                let blenderVer = stats["blender_version"] as? String ?? "unknown"

                var msg = "Created \(filename) at \(path) — \(verts) vertices, \(faces) faces, \(sizeKB)KB (Blender \(blenderVer))"

                // Surface validation warnings
                if let validation = json["validation"] as? [String: Any],
                   let warnings = validation["warnings"] as? [String], !warnings.isEmpty {
                    msg += "\n\nValidation warnings:\n" + warnings.map { "- \($0)" }.joined(separator: "\n")
                }

                return msg
            } else {
                let error = json["error"] as? String ?? "Unknown error"
                let tb = json["traceback"] as? String
                var msg = "3D model creation failed: \(error)"
                if let tb = tb {
                    // Show last few lines of traceback for debugging
                    let lines = tb.components(separatedBy: "\n").suffix(5)
                    msg += "\n\nTraceback:\n" + lines.joined(separator: "\n")
                }
                return msg
            }
        }

        // If we can't parse JSON but file exists, it probably worked
        if FileManager.default.fileExists(atPath: outputPath) {
            return "Created \(filename) at \(outputPath)"
        }

        // Report error with stderr
        if !result.stderr.isEmpty {
            // Filter out Blender's noisy startup messages
            let meaningful = result.stderr.components(separatedBy: "\n")
                .filter { !$0.contains("Blender") || $0.contains("Error") || $0.contains("error") }
                .prefix(10)
                .joined(separator: "\n")
            if !meaningful.isEmpty {
                return "3D model creation failed: \(meaningful)"
            }
        }

        return "3D model creation failed: No output from engine. Exit code: \(result.exitCode)"
    }
}

// MARK: - Blender Executor Helpers

enum BlenderExecutor {
    struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Cached Blender path — detected once, reused.
    private static var cachedBlenderPath: String?

    /// Find Blender executable. Returns nil if not installed.
    static func findBlender() -> String? {
        if let cached = cachedBlenderPath { return cached }

        let candidates = [
            "/Applications/Blender.app/Contents/MacOS/Blender",
            NSHomeDirectory() + "/Applications/Blender.app/Contents/MacOS/Blender",
            "/opt/homebrew/bin/blender",
            "/usr/local/bin/blender",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedBlenderPath = path
                return path
            }
        }

        // Try `which blender`
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["blender"]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        try? whichProcess.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty && FileManager.default.isExecutableFile(atPath: output) {
            cachedBlenderPath = output
            return output
        }

        return nil
    }

    /// Copy a resource from the app bundle to the Executer App Support directory.
    static func ensureResource(_ name: String, ext: String, in dir: URL) {
        let dest = dir.appendingPathComponent("\(name).\(ext)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: bundled, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }

    /// Run Blender in headless mode with a Python script.
    /// CRITICAL: Reads pipes BEFORE waitUntilExit to avoid deadlock on large output.
    static func runBlender(blender: String, script: String, args: [String],
                           timeoutSeconds: Int = 120) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                // blender -b --python script.py -- --spec ... --output ...
                process.executableURL = URL(fileURLWithPath: blender)
                process.arguments = ["-b", "--python", script, "--"] + args
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment

                do {
                    try process.run()

                    // Timeout: kill Blender if it runs too long
                    let pid = process.processIdentifier
                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
                    timer.setEventHandler {
                        if process.isRunning {
                            kill(pid, SIGTERM)
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                if process.isRunning { kill(pid, SIGKILL) }
                            }
                        }
                    }
                    timer.resume()

                    // Read pipes BEFORE waitUntilExit to avoid deadlock when output exceeds ~64KB
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    timer.cancel()

                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""

                    // Check if killed by timeout
                    if process.terminationStatus == SIGTERM || process.terminationStatus == SIGKILL {
                        continuation.resume(returning: ProcessResult(
                            stdout: "{\"success\": false, \"error\": \"Blender timed out after \(timeoutSeconds) seconds. The bpy_code may have an infinite loop or be too complex.\"}",
                            stderr: err,
                            exitCode: process.terminationStatus
                        ))
                        return
                    }

                    continuation.resume(returning: ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
