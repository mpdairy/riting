# riting-assistant

An Emacs minor mode for collaborative creative writing with a local LLM. You write, and after a configurable number of words, the AI continues the story for a few words — adding a little scramble and misdirection to your flow.

## Setup

### 1. Install Ollama

```bash
curl -fsSL https://ollama.ai/install.sh | sh
```

### 2. Pull a lightweight model

For modest hardware, pick one of these:

```bash
ollama pull tinyllama       # ~637MB, runs on almost anything
ollama pull phi3:mini       # ~2.3GB, better quality
ollama pull gemma:2b        # ~1.4GB, good middle ground
```

### 3. Start Ollama

```bash
ollama serve
```

### 4. Add to Emacs

Add to your `init.el`:

```elisp
(add-to-list 'load-path "/path/to/riting_assistant")
(require 'riting-assistant)

;; Optional: customize defaults
(setq riting-assistant-user-words 100)  ;; words you write before AI kicks in
(setq riting-assistant-ai-words 10)     ;; words the AI writes
(setq riting-assistant-model "tinyllama")
```

## Usage

- `M-x riting-assistant-mode` — toggle the mode on/off
- The mode line shows `[riting:45/100]` — your progress toward the next AI insertion
- When you hit the word threshold, the AI automatically continues your story
- AI-generated text appears in italic gray so you can tell it apart

### Keybindings (active when mode is on)

| Key       | Command                            |
|-----------|------------------------------------|
| `C-c r g` | Generate now (skip the word count) |
| `C-c r r` | Reset word counter                 |
| `C-c r u` | Change user word count             |
| `C-c r a` | Change AI word count               |

## How it works

1. You write freely in any buffer with `riting-assistant-mode` enabled
2. The mode counts your words as you type
3. When you hit the threshold (default 100 words), it sends the last ~200 words of context to your local Ollama instance
4. The LLM continues the story for ~10 words (configurable)
5. The generated text is inserted at the end, styled differently so you can see it
6. The counter resets and you keep writing
