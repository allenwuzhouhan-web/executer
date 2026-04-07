#!/usr/bin/env python3
"""
Self-validation test suite for Video Design Coach.

Runs 15 test questions against the coach and checks that responses contain
expected keywords/numbers from the knowledge base.

Usage:
    export DEEPSEEK_API_KEY=sk-...
    python3 test_video_coach.py
"""

import sys
from pathlib import Path

# Import from sibling module
sys.path.insert(0, str(Path(__file__).parent))
from video_coach import create_client, load_system_prompt, ask, MODEL

# Each test: (category, question, expected_keywords)
# expected_keywords: response must contain ALL of these (case-insensitive)
TESTS = [
    # Pre-Production
    (
        "Script pacing",
        "How fast should narration be in a training video?",
        ["120", "140"],  # 120-140 wpm
    ),
    (
        "Cognitive load",
        "How long before viewers lose attention in a training video?",
        ["6", "minute"],  # 6 minutes
    ),
    (
        "Scene segmentation",
        "How long should each segment of my video script be?",
        ["20", "30", "second"],  # 20-30 seconds
    ),
    (
        "Front-loading",
        "Where should I put the main message in my video?",
        ["5", "second"],  # first 5 seconds
    ),
    (
        "6-word rule",
        "How much text should I put on screen at once?",
        ["6", "word"],  # 6 words or fewer
    ),

    # Production
    (
        "Lighting setup",
        "How should I light my video?",
        ["three", "key", "fill"],  # three-point: key, fill, backlight
    ),
    (
        "Composition",
        "How do I frame my subject in a video?",
        ["thirds"],  # rule of thirds
    ),
    (
        "Audio priority",
        "What's more important, video quality or audio quality?",
        ["audio"],  # audio is more important
    ),
    (
        "Visual state changes",
        "How often should I change what's on screen?",
        ["3", "6", "second"],  # every 3-6 seconds
    ),

    # Post-Production
    (
        "Typography sizes",
        "What font size should I use for headings in a 1080p video?",
        ["48", "64"],  # 48-64px
    ),
    (
        "Body text size",
        "What font size for body text in video?",
        ["28", "36"],  # 28-36px
    ),
    (
        "Contrast ratio",
        "What contrast ratio do I need for accessible video text?",
        ["4.5"],  # 4.5:1 WCAG AA
    ),

    # Platform
    (
        "Aspect ratios",
        "What aspect ratio should I use for YouTube vs TikTok?",
        ["16:9", "9:16"],  # YouTube=16:9, TikTok=9:16
    ),
    (
        "LinkedIn video length",
        "How long should LinkedIn videos be?",
        ["3", "10"],  # 3-10 minutes
    ),

    # Branding
    (
        "Brand recognition",
        "How does consistent branding help my videos?",
        ["recognition"],  # brand recognition
    ),
]


def run_tests(verbose: bool = True) -> tuple[int, int, float]:
    """Run all tests. Returns (passed, total, total_cost)."""
    client = create_client()
    system = load_system_prompt()
    total_cost = 0.0
    passed = 0
    failed_details = []

    print(f"Running {len(TESTS)} validation tests using {MODEL}...\n")

    for i, (category, question, expected) in enumerate(TESTS, 1):
        # Fresh history per test (no cross-contamination)
        history = []
        try:
            answer, cost = ask(client, system, history, question)
            total_cost += cost
        except Exception as e:
            print(f"  [{i:2d}] FAIL  {category}: API error — {e}")
            failed_details.append((category, question, f"API error: {e}"))
            continue

        answer_lower = answer.lower()
        missing = [kw for kw in expected if kw.lower() not in answer_lower]

        if not missing:
            passed += 1
            if verbose:
                print(f"  [{i:2d}] PASS  {category}")
        else:
            if verbose:
                print(f"  [{i:2d}] FAIL  {category}")
                print(f"         Missing: {missing}")
                # Show first 150 chars of response for debugging
                print(f"         Response: {answer[:150]}...")
            failed_details.append((category, question, f"Missing keywords: {missing}"))

    print(f"\n{'=' * 50}")
    print(f"Results: {passed}/{len(TESTS)} passed")
    print(f"Total API cost: ${total_cost:.4f}")
    print(f"{'=' * 50}")

    if failed_details:
        print(f"\nFailed tests:")
        for cat, q, reason in failed_details:
            print(f"  - {cat}: {reason}")

    return passed, len(TESTS), total_cost


if __name__ == "__main__":
    passed, total, cost = run_tests(verbose=True)
    sys.exit(0 if passed == total else 1)
