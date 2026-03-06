#!/usr/bin/env python3
"""
LLM generation script for Audio Transcriber 9000.
Accepts a messages JSON array and streams generated text to stdout.

Usage:
    python generate.py --messages '[{"role":"user","content":"Hello"}]' \
                       --system "You are a helpful assistant." \
                       --model mlx-community/Mistral-7B-Instruct-v0.3-4bit \
                       --max-tokens 1000
"""
import sys
import json
import argparse
import os

# Suppress tokenizer parallelism warnings
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')


def main():
    parser = argparse.ArgumentParser(description='Stream LLM generation via mlx-lm')
    parser.add_argument('--system', type=str, default=None,
                        help='System prompt (prepended to messages)')
    parser.add_argument('--messages', type=str, required=True,
                        help='JSON array of {"role": ..., "content": ...} objects')
    parser.add_argument('--model', type=str,
                        default='mlx-community/Mistral-7B-Instruct-v0.3-4bit',
                        help='HuggingFace model ID or local path')
    parser.add_argument('--max-tokens', type=int, default=1000,
                        help='Maximum tokens to generate')
    args = parser.parse_args()

    try:
        messages = json.loads(args.messages)
    except json.JSONDecodeError as e:
        print(f'Error parsing messages JSON: {e}', file=sys.stderr)
        sys.exit(1)

    if args.system:
        messages = [{'role': 'system', 'content': args.system}] + messages

    try:
        from mlx_lm import load, stream_generate
    except ImportError:
        print('mlx_lm not installed. Run: pip install mlx-lm', file=sys.stderr)
        sys.exit(1)

    try:
        model, tokenizer = load(args.model)
    except Exception as e:
        print(f'Error loading model {args.model!r}: {e}', file=sys.stderr)
        sys.exit(1)

    # Apply chat template if the tokenizer supports it
    if hasattr(tokenizer, 'apply_chat_template') and tokenizer.chat_template is not None:
        try:
            prompt = tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True
            )
        except Exception:
            # Fallback if chat template fails
            prompt = _format_messages_fallback(messages)
    else:
        prompt = _format_messages_fallback(messages)

    try:
        for response in stream_generate(model, tokenizer, prompt=prompt, max_tokens=args.max_tokens):
            text = response.text if hasattr(response, 'text') else str(response)
            sys.stdout.write(text)
            sys.stdout.flush()
    except Exception as e:
        print(f'\nGeneration error: {e}', file=sys.stderr)
        sys.exit(1)


def _format_messages_fallback(messages):
    """Simple fallback formatting when no chat template is available."""
    parts = []
    for m in messages:
        role = m.get('role', 'user')
        content = m.get('content', '')
        if role == 'system':
            parts.append(f'System: {content}')
        elif role == 'user':
            parts.append(f'User: {content}')
        elif role == 'assistant':
            parts.append(f'Assistant: {content}')
        else:
            parts.append(f'{role}: {content}')
    return '\n'.join(parts) + '\nAssistant: '


if __name__ == '__main__':
    main()
