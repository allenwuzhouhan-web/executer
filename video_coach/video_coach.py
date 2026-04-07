#!/usr/bin/env python3
"""
Video Design Coach — NotebookLM-style interactive teaching via DeepSeek.

Usage:
    export DEEPSEEK_API_KEY=sk-...
    python3 video_coach.py

Cost: ~$0.001 per exchange using deepseek-chat.
"""

import os
import sys
from pathlib import Path

try:
    from openai import OpenAI, APIError
except ImportError:
    print("Error: openai package not installed. Run: pip3 install openai")
    sys.exit(1)

MODEL = "deepseek-chat"
BASE_URL = "https://api.deepseek.com"
MAX_TOKENS = 1024


def load_system_prompt() -> str:
    """Load system prompt from the file next to this script."""
    prompt_path = Path(__file__).parent / "system_prompt.txt"
    if not prompt_path.exists():
        print(f"Error: system_prompt.txt not found at {prompt_path}")
        sys.exit(1)
    return prompt_path.read_text().strip()


def create_client() -> OpenAI:
    """Create DeepSeek client via OpenAI-compatible API."""
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        print("Error: DEEPSEEK_API_KEY not set.")
        print("  export DEEPSEEK_API_KEY=sk-...")
        sys.exit(1)
    return OpenAI(api_key=api_key, base_url=BASE_URL)


def ask(client: OpenAI, system: str, history: list[dict], question: str) -> tuple[str, float]:
    """Send a question and return (response, cost). Appends to history in-place."""
    history.append({"role": "user", "content": question})

    messages = [{"role": "system", "content": system}] + history

    response = client.chat.completions.create(
        model=MODEL,
        max_tokens=MAX_TOKENS,
        messages=messages,
    )

    answer = response.choices[0].message.content
    history.append({"role": "assistant", "content": answer})

    # DeepSeek pricing: $0.27/M input, $1.10/M output (cache miss)
    usage = response.usage
    input_tokens = usage.prompt_tokens
    output_tokens = usage.completion_tokens
    cost = (input_tokens * 0.27 + output_tokens * 1.10) / 1_000_000

    return answer, cost


def main():
    print("=" * 60)
    print("  Video Design Coach")
    print("  Powered by DeepSeek — ask anything about video design")
    print("  Type 'quit' to exit, 'checklist' for a production checklist")
    print("=" * 60)
    print()

    client = create_client()
    system = load_system_prompt()
    history = []
    total_cost = 0.0

    while True:
        try:
            question = input("\033[1mYou:\033[0m ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nGoodbye!")
            break

        if not question:
            continue
        if question.lower() in ("quit", "exit", "q"):
            print(f"\nSession cost: ${total_cost:.4f}")
            print("Goodbye!")
            break

        # Shortcut commands
        if question.lower() == "checklist":
            question = "Give me a complete video production checklist organized by phase: pre-production, production, and post-production."
        elif question.lower() == "style guide":
            question = "Generate a template style guide I can fill in for my brand's videos."

        try:
            answer, cost = ask(client, system, history, question)
            total_cost += cost
            print(f"\n\033[1mCoach:\033[0m {answer}")
            print(f"\033[2m[${cost:.4f} | session total: ${total_cost:.4f}]\033[0m\n")
        except APIError as e:
            print(f"\nAPI error: {e}\n")
        except Exception as e:
            print(f"\nError: {e}\n")


if __name__ == "__main__":
    main()
