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
        except Exception as e:
            print(f'Warning: chat template failed ({e}), using fallback format', file=sys.stderr)
            prompt = _format_messages_fallback(messages)
    else:
        prompt = _format_messages_fallback(messages)

    # Stop sequences: prevent model from roleplaying further conversation turns
    stop_sequences = ['\nUser:', '\nHuman:', '\n[INST]', '\nUSER:', '\nHUMAN:',
                      '\n<|im_start|>user', '\n<|user|>', '\n\nUser:', '\n\nHuman:']
    tail_len = max(len(s) for s in stop_sequences)

    try:
        buffer = ''
        stopped = False
        for response in stream_generate(model, tokenizer, prompt=prompt, max_tokens=args.max_tokens):
            text = response.text if hasattr(response, 'text') else str(response)
            buffer += text

            # Check if any stop sequence appeared in the buffer
            stop_idx = None
            for seq in stop_sequences:
                idx = buffer.find(seq)
                if idx != -1 and (stop_idx is None or idx < stop_idx):
                    stop_idx = idx

            if stop_idx is not None:
                sys.stdout.write(buffer[:stop_idx])
                sys.stdout.flush()
                stopped = True
                break

            # Flush safe portion (keep tail in buffer for partial stop seq detection)
            if len(buffer) > tail_len:
                sys.stdout.write(buffer[:-tail_len])
                sys.stdout.flush()
                buffer = buffer[-tail_len:]

        if not stopped:
            sys.stdout.write(buffer)
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
            parts.append(f'<s>[INST] <<SYS>>\n{content}\n<</SYS>>\n\n')
        elif role == 'user':
            parts.append(f'[INST] {content} [/INST]')
        elif role == 'assistant':
            parts.append(f' {content} </s>')
    # End with opening for assistant response
    return ''.join(parts)


if __name__ == '__main__':
    main()
