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


END_MARKER = '\x1e<<END:'
READY_MARKER = '\x1e<<READY>>'

# Stop sequences: prevent model from roleplaying further conversation turns
STOP_SEQUENCES = ['\nUser:', '\nHuman:', '\n[INST]', '\nUSER:', '\nHUMAN:',
                  '\n<|im_start|>user', '\n<|user|>', '\n\nUser:', '\n\nHuman:']
TAIL_LEN = max(len(s) for s in STOP_SEQUENCES)


def build_prompt(tokenizer, messages):
    """Apply the tokenizer chat template, falling back to [INST] format."""
    if hasattr(tokenizer, 'apply_chat_template') and tokenizer.chat_template is not None:
        try:
            return tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True)
        except Exception as e:
            print(f'Warning: chat template failed ({e}), using fallback format', file=sys.stderr)
    return _format_messages_fallback(messages)


def generate_streaming(model, tokenizer, stream_generate, messages, max_tokens):
    """Stream tokens to stdout with stop-sequence detection."""
    prompt = build_prompt(tokenizer, messages)
    buffer = ''
    stopped = False
    for response in stream_generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens):
        text = response.text if hasattr(response, 'text') else str(response)
        buffer += text

        stop_idx = None
        for seq in STOP_SEQUENCES:
            idx = buffer.find(seq)
            if idx != -1 and (stop_idx is None or idx < stop_idx):
                stop_idx = idx

        if stop_idx is not None:
            sys.stdout.write(buffer[:stop_idx])
            sys.stdout.flush()
            stopped = True
            break

        if len(buffer) > TAIL_LEN:
            sys.stdout.write(buffer[:-TAIL_LEN])
            sys.stdout.flush()
            buffer = buffer[-TAIL_LEN:]

    if not stopped:
        sys.stdout.write(buffer)
        sys.stdout.flush()


def run_server(model_name):
    """Persistent mode: load the model once, then serve one JSON request per
    stdin line, terminating each response with an END sentinel."""
    try:
        from mlx_lm import load, stream_generate
    except ImportError:
        sys.stdout.write(f'{END_MARKER}err:mlx_lm not installed>>\n')
        sys.stdout.flush()
        sys.exit(1)

    try:
        model, tokenizer = load(model_name)
    except Exception as e:
        sys.stdout.write(f'{END_MARKER}err:model load failed: {e}>>\n')
        sys.stdout.flush()
        sys.exit(1)

    sys.stdout.write(f'{READY_MARKER}\n')
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            messages = request['messages']
            if request.get('system'):
                messages = [{'role': 'system', 'content': request['system']}] + messages
            max_tokens = int(request.get('max_tokens', 800))
            generate_streaming(model, tokenizer, stream_generate, messages, max_tokens)
            sys.stdout.write(f'{END_MARKER}ok>>\n')
            sys.stdout.flush()
        except Exception as e:
            message = str(e).replace('>>', '').replace('\n', ' ')[:300]
            sys.stdout.write(f'{END_MARKER}err:{message}>>\n')
            sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description='Stream LLM generation via mlx-lm')
    parser.add_argument('--system', type=str, default=None,
                        help='System prompt (prepended to messages)')
    parser.add_argument('--messages', type=str, default=None,
                        help='JSON array of {"role": ..., "content": ...} objects')
    parser.add_argument('--model', type=str,
                        default='mlx-community/Mistral-7B-Instruct-v0.3-4bit',
                        help='HuggingFace model ID or local path')
    parser.add_argument('--max-tokens', type=int, default=1000,
                        help='Maximum tokens to generate')
    parser.add_argument('--server', action='store_true',
                        help='Persistent mode: read JSON requests from stdin')
    args = parser.parse_args()

    if args.server:
        run_server(args.model)
        return

    if not args.messages:
        print('Either --messages or --server is required', file=sys.stderr)
        sys.exit(1)

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

    try:
        generate_streaming(model, tokenizer, stream_generate, messages, args.max_tokens)
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
