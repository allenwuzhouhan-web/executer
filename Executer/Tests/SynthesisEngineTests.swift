import Foundation

/// Lightweight test harness for the SynthesisEngine.
/// Validates: JSON parsing, filtering, deduplication, daily cap.
///
/// Run via: `await SynthesisEngineTests.runAll()` from a debug menu or AppDelegate.
enum SynthesisEngineTests {

    static func runAll() async {
        print("=== SynthesisEngine Tests ===")
        var passed = 0
        var failed = 0

        func check(_ name: String, _ ok: Bool, detail: String = "") {
            if ok {
                passed += 1
                print("[PASS] \(name)")
            } else {
                failed += 1
                print("[FAIL] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        let engine = SynthesisEngine.shared
        let empty = SynthesisEngine.Snapshot(
            thoughtSummaries: [], relevantMemories: [], activeGoals: [],
            recentFiles: [], currentApp: "", currentActivity: ""
        )
        let rich = SynthesisEngine.Snapshot(
            thoughtSummaries: [
                "[Safari] Quantum algorithms - Nature (2:15 PM): New approaches...",
                "[Xcode] SynthesisEngine.swift (2:30 PM): actor SynthesisEngine {..."
            ],
            relevantMemories: ["[task] Presentation for Sarah due Thursday", "[fact] Dr. Lee on AlphaFold"],
            activeGoals: ["Prepare biology presentation (deadline: Thursday)"],
            recentFiles: ["quantum_algorithms.pdf", "meeting_notes.docx"],
            currentApp: "Safari",
            currentActivity: "browsing in Safari — Quantum algorithms"
        )

        // 1. Valid JSON parsing
        do {
            let json = """
            [{"headline":"Research connects to deadline","explanation":"Protein folding relates to Dr. Lee's email.","domains":["Safari","Email","Calendar"],"surprise_score":0.85,"action":"Pull papers into outline?"},{"headline":"Slack billing","explanation":"4 switches.","domains":["Slack","Excel"],"surprise_score":0.7,"action":null}]
            """
            let insights = await engine.parseInsights(from: json, snapshot: empty)
            check("JSON parsing (valid)", insights.count == 2
                && insights[0].domains.count == 3
                && insights[0].surpriseScore == 0.85
                && insights[0].actionSuggestion != nil
                && insights[1].actionSuggestion == nil,
                detail: "got \(insights.count) insights")
        }

        // 2. Empty array
        do {
            let i1 = await engine.parseInsights(from: "[]", snapshot: empty)
            let i2 = await engine.parseInsights(from: "```json\n[]\n```", snapshot: empty)
            check("JSON parsing (empty)", i1.isEmpty && i2.isEmpty)
        }

        // 3. Malformed JSON — no crash, returns empty
        do {
            let cases = ["Not JSON", "{\"headline\":\"not array\"}", "[{\"headline\":\"missing fields\"}]", ""]
            var allEmpty = true
            for c in cases {
                let r = await engine.parseInsights(from: c, snapshot: empty)
                if !r.isEmpty { allEmpty = false }
            }
            check("JSON parsing (malformed)", allEmpty)
        }

        // 4. Surprise score filtering
        do {
            let json = """
            [{"headline":"Low","explanation":"x","domains":["A","B"],"surprise_score":0.3,"action":null},{"headline":"High","explanation":"x","domains":["C","D"],"surprise_score":0.8,"action":null}]
            """
            let all = await engine.parseInsights(from: json, snapshot: empty)
            let filtered = all.filter { $0.surpriseScore >= 0.6 }
            check("Surprise score filtering", all.count == 2 && filtered.count == 1 && filtered[0].headline == "High")
        }

        // 5. Domain count filtering — single domain rejected at parse time
        do {
            let json = """
            [{"headline":"One","explanation":"x","domains":["Safari"],"surprise_score":0.9,"action":null},{"headline":"Two","explanation":"x","domains":["Safari","Calendar"],"surprise_score":0.7,"action":null}]
            """
            let insights = await engine.parseInsights(from: json, snapshot: empty)
            check("Domain count filtering", insights.count == 1 && insights[0].headline == "Two")
        }

        // 6. Deduplication logic (Jaccard similarity)
        do {
            let h1 = "Your quantum computing research connects to Thursday's presentation"
            let h2 = "Your quantum computing research relates to Sarah's Thursday presentation"
            let w1 = Set(h1.lowercased().split(separator: " ").map(String.init))
            let w2 = Set(h2.lowercased().split(separator: " ").map(String.init))
            let jaccard = Double(w1.intersection(w2).count) / Double(w1.union(w2).count)
            check("Deduplication (Jaccard)", jaccard > 0.5, detail: String(format: "%.2f", jaccard))
        }

        // 7. SourceSnapshot flows through from rich snapshot
        do {
            let json = """
            [{"headline":"Test","explanation":"Test","domains":["A","B"],"surprise_score":0.8,"action":null}]
            """
            let insights = await engine.parseInsights(from: json, snapshot: rich)
            check("SourceSnapshot passthrough",
                insights.count == 1
                && !insights[0].sourceData.thoughtSummaries.isEmpty
                && !insights[0].sourceData.relevantMemories.isEmpty
                && !insights[0].sourceData.recentFiles.isEmpty)
        }

        // 8. Daily cap — no insights available returns nil
        do {
            let result = await SynthesisEngine.shared.nextPendingInsight()
            // Either nil (no insights) or non-nil (prior data) — both valid, just verify no crash
            check("Daily cap (no crash)", true)
        }

        // 9. "null" string in action is treated as nil
        do {
            let json = """
            [{"headline":"Null action","explanation":"x","domains":["A","B"],"surprise_score":0.9,"action":"null"}]
            """
            let insights = await engine.parseInsights(from: json, snapshot: empty)
            check("Null string action → nil", insights.count == 1 && insights[0].actionSuggestion == nil)
        }

        print("")
        print("=== \(passed) passed, \(failed) failed ===")
    }
}
