;;; riting-assistant.el --- Local LLM co-writing minor mode -*- lexical-binding: t; -*-

;; Author: teddy
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: writing, ai
;; URL: https://github.com/teddy/riting-assistant

;;; Commentary:

;; A creative writing minor mode that counts your words as you type.
;; After you write a configured number of words, an LLM streams the
;; next few words into your buffer in real-time, as if it were typing
;; alongside you.
;;
;; Supports two backends:
;;   - ollama: Local LLM via Ollama (default)
;;   - groq:   Fast cloud inference via Groq API
;;
;; Usage:
;;   M-x riting-assistant-mode   to toggle
;;
;; Requirements (Ollama backend):
;;   - Ollama running locally (https://ollama.ai)
;;   - A model pulled, e.g.: ollama pull qwen2.5:3b
;;
;; Requirements (Groq backend):
;;   - A Groq API key (set GROQ_API_KEY env var or customize
;;     riting-assistant-groq-api-key)
;;
;; Configuration:
;;   (setq riting-assistant-backend 'ollama)  ; or 'groq
;;   (setq riting-assistant-user-words-min 15)
;;   (setq riting-assistant-user-words-max 45)
;;   (setq riting-assistant-ai-words-min 5)
;;   (setq riting-assistant-ai-words-max 10)
;;   (setq riting-assistant-model "qwen2.5:3b")        ; for ollama
;;   (setq riting-assistant-groq-model "llama-3.1-8b-instant") ; for groq
;;
;; Debug:
;;   C-c r d to view *riting-debug* buffer with full logs.

;;; Code:

(require 'json)

;; --- Customization ---

(defgroup riting-assistant nil
  "Local LLM co-writing assistant."
  :group 'text
  :prefix "riting-assistant-")

(defcustom riting-assistant-user-words-min 15
  "Minimum words you write before the AI might kick in."
  :type 'integer
  :group 'riting-assistant)

(defcustom riting-assistant-user-words-max 45
  "Maximum words you write before the AI kicks in."
  :type 'integer
  :group 'riting-assistant)

(defcustom riting-assistant-ai-words-min 10
  "Minimum words the AI writes."
  :type 'integer
  :group 'riting-assistant)

(defcustom riting-assistant-ai-words-max 20
  "Maximum words the AI writes."
  :type 'integer
  :group 'riting-assistant)

(defcustom riting-assistant-model "llama3.1:8b"
  "Ollama model to use for generation."
  :type 'string
  :group 'riting-assistant)

(defcustom riting-assistant-ollama-url "http://localhost:11434"
  "Base URL for the Ollama API."
  :type 'string
  :group 'riting-assistant)

(defcustom riting-assistant-backend 'ollama
  "Backend to use for LLM generation.
`ollama' uses a local Ollama instance.
`groq' uses the Groq cloud API."
  :type '(choice (const :tag "Ollama (local)" ollama)
                 (const :tag "Groq (cloud)" groq))
  :group 'riting-assistant)

(defcustom riting-assistant-groq-api-key nil
  "API key for Groq.  If nil, reads from GROQ_API_KEY env var."
  :type '(choice (const :tag "Use GROQ_API_KEY env var" nil)
                 (string :tag "API key"))
  :group 'riting-assistant)

(defcustom riting-assistant-groq-model "llama-3.1-8b-instant"
  "Model to use with the Groq backend."
  :type 'string
  :group 'riting-assistant)

(defcustom riting-assistant-groq-url "https://api.groq.com/openai/v1"
  "Base URL for the Groq API."
  :type 'string
  :group 'riting-assistant)

;; --- Internal state ---

(defvar-local riting-assistant--word-count 0
  "Words typed by the user since the last AI generation.")

(defvar-local riting-assistant--generating nil
  "Non-nil when the AI is currently generating text.")

(defvar-local riting-assistant--prev-word-count 0
  "Buffer word count at last check, used to compute delta.")

(defvar-local riting-assistant--current-user-target 20
  "Current randomized word target for the user.")

(defvar-local riting-assistant--current-ai-target 5
  "Current randomized word count for the AI.")

(defvar-local riting-assistant--stream-word-count 0
  "Number of words inserted so far during current streaming generation.")

(defvar-local riting-assistant--stream-partial ""
  "Partial JSON line buffer for streaming responses.")

(defvar-local riting-assistant--stream-accumulated ""
  "All tokens received so far in the current generation.")

(defvar-local riting-assistant--stream-proc nil
  "The current streaming curl process.")

(defvar-local riting-assistant--first-token t
  "Non-nil if we haven't received a token yet in this generation.")

(defvar riting-assistant--call-counter 0
  "Counter for unique process names.")

;; --- Helpers ---

(defun riting-assistant--groq-api-key ()
  "Return the Groq API key, or signal an error if not set."
  (or riting-assistant-groq-api-key
      (getenv "GROQ_API_KEY")
      (error "Groq API key not set — customize `riting-assistant-groq-api-key' or set GROQ_API_KEY env var")))

(defun riting-assistant--active-model ()
  "Return the model name for the current backend."
  (pcase riting-assistant-backend
    ('ollama riting-assistant-model)
    ('groq riting-assistant-groq-model)))

(defun riting-assistant--random-range (min max)
  "Return a random integer between MIN and MAX inclusive."
  (+ min (random (1+ (- max min)))))

(defun riting-assistant--roll-targets ()
  "Pick new random targets for user and AI word counts."
  (setq riting-assistant--current-user-target
        (riting-assistant--random-range
         riting-assistant-user-words-min
         riting-assistant-user-words-max))
  (setq riting-assistant--current-ai-target
        (riting-assistant--random-range
         riting-assistant-ai-words-min
         riting-assistant-ai-words-max)))

;; --- Debug logging ---

(defun riting-assistant--debug-log (msg)
  "Log MSG to the *riting-debug* buffer."
  (let ((buf (get-buffer-create "*riting-debug*")))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] ") msg "\n\n"))))

;; --- Word counting ---

(defun riting-assistant--buffer-word-count ()
  "Count total words in the buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((count 0))
      (while (forward-word-strictly 1)
        (setq count (1+ count)))
      count)))

;; --- Streaming API ---

(defun riting-assistant--stream-filter (proc output)
  "Process filter for streaming responses.
Dispatches to the appropriate parser based on backend."
  (pcase (process-get proc 'backend)
    ('groq (riting-assistant--groq-stream-filter proc output))
    (_ (riting-assistant--ollama-stream-filter proc output))))

(defun riting-assistant--groq-stream-filter (proc output)
  "Process filter for streaming Groq (OpenAI-compatible SSE) responses.
Parses `data: {...}' lines from OUTPUT and inserts tokens into the writing buffer."
  (let ((writing-buf (process-get proc 'writing-buffer)))
    (when (buffer-live-p writing-buf)
      (with-current-buffer writing-buf
        (setq riting-assistant--stream-partial
              (concat riting-assistant--stream-partial output))
        (let ((lines (split-string riting-assistant--stream-partial "\n" t))
              (finished nil))
          (if (string-suffix-p "\n" riting-assistant--stream-partial)
              (setq riting-assistant--stream-partial "")
            (setq riting-assistant--stream-partial (car (last lines)))
            (setq lines (butlast lines)))
          (dolist (line lines)
            (when (and (not finished) (string-prefix-p "data: " line))
              (let ((payload (substring line 6)))
                (if (string= payload "[DONE]")
                    (progn
                      (setq finished t)
                      (riting-assistant--stream-finish proc))
                  (condition-case nil
                      (let* ((json-object-type 'alist)
                             (json-array-type 'list)
                             (resp (json-read-from-string payload))
                             (choices (alist-get 'choices resp))
                             (delta (alist-get 'delta (car choices)))
                             (token (alist-get 'content delta)))
                        (when (and token (> (length token) 0))
                          (setq riting-assistant--stream-accumulated
                                (concat riting-assistant--stream-accumulated token))
                          (let ((inhibit-read-only t))
                            (when riting-assistant--first-token
                              (setq riting-assistant--first-token nil)
                              (save-excursion
                                (goto-char (point-max))
                                (when (and (not (bobp))
                                           (not (memq (char-before) '(?\s ?\n ?\t))))
                                  (insert " "))))
                            (save-excursion
                              (goto-char (point-max))
                              (insert token)))
                          (let* ((trimmed (string-trim riting-assistant--stream-accumulated))
                                 (words (if (> (length trimmed) 0)
                                            (split-string trimmed "[ \t\n]+" t)
                                          nil)))
                            (setq riting-assistant--stream-word-count (length words))
                            (riting-assistant--debug-log
                             (format "TOKEN: %S  accumulated-words=%d/%d"
                                     token riting-assistant--stream-word-count
                                     riting-assistant--current-ai-target)))
                          (when (>= riting-assistant--stream-word-count
                                    riting-assistant--current-ai-target)
                            (setq finished t)
                            (riting-assistant--stream-finish proc))))
                    (error nil)))))))))))

(defun riting-assistant--ollama-stream-filter (proc output)
  "Process filter for streaming Ollama responses.
Parses JSON lines from OUTPUT and inserts tokens into the writing buffer."
  (let ((writing-buf (process-get proc 'writing-buffer)))
    (when (buffer-live-p writing-buf)
      (with-current-buffer writing-buf
        (setq riting-assistant--stream-partial
              (concat riting-assistant--stream-partial output))
        (let ((lines (split-string riting-assistant--stream-partial "\n" t))
              (finished nil))
          (if (string-suffix-p "\n" riting-assistant--stream-partial)
              (setq riting-assistant--stream-partial "")
            (setq riting-assistant--stream-partial (car (last lines)))
            (setq lines (butlast lines)))
          (dolist (line lines)
            (when (and (> (length line) 0) (not finished))
              (condition-case nil
                  (let* ((json-object-type 'alist)
                         (json-array-type 'list)
                         (resp (json-read-from-string line))
                         (token (alist-get 'content (alist-get 'message resp)))
                         (done (eq (alist-get 'done resp) t)))
                    (when (and token (> (length token) 0))
                      ;; Accumulate token text
                      (setq riting-assistant--stream-accumulated
                            (concat riting-assistant--stream-accumulated token))
                      ;; Insert into the writing buffer
                      (let ((inhibit-read-only t))
                        (when riting-assistant--first-token
                          (setq riting-assistant--first-token nil)
                          (save-excursion
                            (goto-char (point-max))
                            (when (and (not (bobp))
                                       (not (memq (char-before) '(?\s ?\n ?\t))))
                              (insert " "))))
                        (save-excursion
                          (goto-char (point-max))
                          (insert token)))
                      ;; Count words in accumulated text
                      (let* ((trimmed (string-trim riting-assistant--stream-accumulated))
                             (words (if (> (length trimmed) 0)
                                        (split-string trimmed "[ \t\n]+" t)
                                      nil)))
                        (setq riting-assistant--stream-word-count (length words))
                        (riting-assistant--debug-log
                         (format "TOKEN: %S  accumulated-words=%d/%d"
                                 token riting-assistant--stream-word-count
                                 riting-assistant--current-ai-target))))
                    (when (or done
                              (>= riting-assistant--stream-word-count
                                  riting-assistant--current-ai-target))
                      (setq finished t)
                      (riting-assistant--stream-finish proc)))
                (error nil)))))))))

(defun riting-assistant--stream-finish (proc)
  "Finish streaming: kill process, trim to word target, unlock buffer."
  (when (process-live-p proc)
    (delete-process proc))
  (let ((writing-buf (process-get proc 'writing-buffer)))
    (when (buffer-live-p writing-buf)
      (with-current-buffer writing-buf
        (let ((inhibit-read-only t)
              (insert-start (process-get proc 'insert-start)))
          (when (and insert-start (> insert-start 0))
            (let* ((generated (buffer-substring-no-properties insert-start (point-max)))
                   (words (split-string generated "[ \t\n]+" t))
                   (trimmed-words (seq-take words riting-assistant--current-ai-target))
                   (trimmed (string-join trimmed-words " ")))
              ;; Replace with trimmed version
              (delete-region insert-start (point-max))
              (goto-char (point-max))
              (insert trimmed)
              (riting-assistant--debug-log
               (format "STREAM DONE: %d words inserted: %s"
                       (length trimmed-words) trimmed)))))
        (setq buffer-read-only nil)
        (setq riting-assistant--generating nil)
        (setq riting-assistant--word-count 0)
        (setq riting-assistant--prev-word-count (riting-assistant--buffer-word-count))
        (setq riting-assistant--stream-proc nil)
        (let ((wrote (min riting-assistant--stream-word-count
                          riting-assistant--current-ai-target)))
          (riting-assistant--roll-targets)
          (message "riting-assistant: AI wrote %d words — keep writing!" wrote))))))

(defun riting-assistant--stream-sentinel (proc _event)
  "Sentinel for streaming process — handles unexpected exits."
  (when (memq (process-status proc) '(exit signal))
    (let ((writing-buf (process-get proc 'writing-buffer)))
      (when (buffer-live-p writing-buf)
        (with-current-buffer writing-buf
          (when riting-assistant--generating
            (riting-assistant--stream-finish proc)))))))

(defun riting-assistant--trigger-generation ()
  "Trigger streaming AI text generation using the entire buffer as context."
  (unless riting-assistant--generating
    (setq riting-assistant--generating t)
    (setq buffer-read-only t)
    (setq riting-assistant--stream-word-count 0)
    (setq riting-assistant--stream-partial "")
    (setq riting-assistant--stream-accumulated "")
    (setq riting-assistant--first-token t)
    (message "riting-assistant: AI is typing...")
    (setq riting-assistant--call-counter (1+ riting-assistant--call-counter))
    (let* ((call-id riting-assistant--call-counter)
           (full-text (buffer-substring-no-properties (point-min) (point-max)))
           (insert-start (point-max))
           (backend riting-assistant-backend)
           (system-msg "You are a creative writing collaborator. Continue the story or text seamlessly from where it left off. Write ONLY the continuation text — no commentary, no numbering, no bullet points, no labels, no meta-text. Match the existing style and tone exactly.")
           (user-msg (format "Continue this text naturally, writing only the next few sentences:\n\n%s" full-text))
           (url (pcase backend
                  ('groq (format "%s/chat/completions" riting-assistant-groq-url))
                  (_ (format "%s/api/chat" riting-assistant-ollama-url))))
           (model (riting-assistant--active-model))
           (request-body
            (pcase backend
              ('groq
               (json-encode
                `((model . ,model)
                  (messages . [((role . "system") (content . ,system-msg))
                               ((role . "user") (content . ,user-msg))])
                  (stream . t)
                  (max_tokens . ,(* riting-assistant--current-ai-target 3))
                  (temperature . 0.9))))
              (_
               (json-encode
                `((model . ,model)
                  (messages . [((role . "system") (content . ,system-msg))
                               ((role . "user") (content . ,user-msg))])
                  (stream . t)
                  (options . ((num_predict . ,(* riting-assistant--current-ai-target 3))
                              (temperature . 0.9))))))))
           (curl-args
            (pcase backend
              ('groq
               (list "curl" "-sN" "--max-time" "120"
                     "-X" "POST" url
                     "-H" "Content-Type: application/json"
                     "-H" (format "Authorization: Bearer %s" (riting-assistant--groq-api-key))
                     "-d" request-body))
              (_
               (list "curl" "-sN" "--max-time" "120"
                     "-X" "POST" url
                     "-H" "Content-Type: application/json"
                     "-d" request-body))))
           (proc-name (format "riting-%s-%d" backend call-id))
           (proc-buf (generate-new-buffer (format " *%s*" proc-name))))
      (riting-assistant--debug-log
       (format ">>> STREAM [%s] (call #%d) model=%s ai_target=%d\nPROMPT (%d chars):\n%s"
               backend call-id model riting-assistant--current-ai-target
               (length full-text) full-text))
      (let ((proc (make-process
                   :name proc-name
                   :buffer proc-buf
                   :command curl-args
                   :filter #'riting-assistant--stream-filter
                   :sentinel #'riting-assistant--stream-sentinel)))
        (process-put proc 'writing-buffer (current-buffer))
        (process-put proc 'insert-start insert-start)
        (process-put proc 'backend backend)
        (setq riting-assistant--stream-proc proc)))))

;; --- Model warmup ---

(defun riting-assistant--warmup ()
  "Send a tiny request to preload the model.  Skipped for cloud backends."
  (pcase riting-assistant-backend
    ('groq
     (message "riting-assistant: using Groq (%s), ready to go!"
              riting-assistant-groq-model))
    (_
     (let* ((url (format "%s/api/chat" riting-assistant-ollama-url))
            (request-body (json-encode
                           `((model . ,riting-assistant-model)
                             (messages . [((role . "user")
                                           (content . "hello"))])
                             (stream . :json-false)
                             (options . ((num_predict . 1)))))))
       (make-process
        :name "riting-warmup"
        :buffer (generate-new-buffer " *riting-warmup*")
        :command (list "curl" "-s" "--max-time" "120"
                       "-X" "POST" url
                       "-H" "Content-Type: application/json"
                       "-d" request-body)
        :sentinel
        (lambda (proc _event)
          (when (memq (process-status proc) '(exit signal))
            (when (buffer-live-p (process-buffer proc))
              (kill-buffer (process-buffer proc)))
            (message "riting-assistant: model loaded, ready to go!"))))))))

;; --- After-change hook ---

(defun riting-assistant--after-change (_beg end _len)
  "Hook called after buffer changes to track word count."
  (when (and riting-assistant-mode
             (not riting-assistant--generating))
    (let* ((current (riting-assistant--buffer-word-count))
           (delta (- current riting-assistant--prev-word-count)))
      (when (> delta 0)
        (setq riting-assistant--word-count (+ riting-assistant--word-count delta))
        (setq riting-assistant--prev-word-count current)
        (force-mode-line-update)))
    (when (and (>= riting-assistant--word-count riting-assistant--current-user-target)
               (<= end (point-max))
               (memq (char-before end) '(?\s ?\n ?\t)))
      (riting-assistant--trigger-generation))))

;; --- Mode line ---

(defun riting-assistant--mode-line ()
  "Return mode line string showing word count progress."
  (if riting-assistant--generating
      " [riting:...]"
    " [riting]"))

;; --- Interactive commands ---

(defun riting-assistant-generate-now ()
  "Manually trigger AI generation regardless of word count."
  (interactive)
  (riting-assistant--trigger-generation))

(defun riting-assistant-reset-count ()
  "Reset the word counter without generating."
  (interactive)
  (setq riting-assistant--word-count 0)
  (message "riting-assistant: word count reset"))

(defun riting-assistant-set-user-range (min max)
  "Set user word range to MIN-MAX for the current buffer."
  (interactive "nMin words before AI kicks in: \nnMax words before AI kicks in: ")
  (setq riting-assistant-user-words-min min)
  (setq riting-assistant-user-words-max max)
  (riting-assistant--roll-targets)
  (message "riting-assistant: user range set to %d-%d" min max))

(defun riting-assistant-set-ai-range (min max)
  "Set AI word range to MIN-MAX for the current buffer."
  (interactive "nMin words for AI: \nnMax words for AI: ")
  (setq riting-assistant-ai-words-min min)
  (setq riting-assistant-ai-words-max max)
  (riting-assistant--roll-targets)
  (message "riting-assistant: AI range set to %d-%d" min max))

(defun riting-assistant-show-debug ()
  "Switch to the *riting-debug* buffer."
  (interactive)
  (switch-to-buffer-other-window (get-buffer-create "*riting-debug*")))

;; --- Minor mode ---

;;;###autoload
(define-minor-mode riting-assistant-mode
  "Minor mode for AI-assisted creative writing.
After you write a random number of words (within a configured range),
a local LLM streams the next few words into your buffer in real-time."
  :lighter (:eval (riting-assistant--mode-line))
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c r g") #'riting-assistant-generate-now)
            (define-key map (kbd "C-c r r") #'riting-assistant-reset-count)
            (define-key map (kbd "C-c r u") #'riting-assistant-set-user-range)
            (define-key map (kbd "C-c r a") #'riting-assistant-set-ai-range)
            (define-key map (kbd "C-c r d") #'riting-assistant-show-debug)
            map)
  (if riting-assistant-mode
      (progn
        (setq riting-assistant--word-count 0)
        (setq riting-assistant--prev-word-count (riting-assistant--buffer-word-count))
        (setq riting-assistant--generating nil)
        (setq riting-assistant--stream-proc nil)
        (riting-assistant--roll-targets)
        (add-hook 'after-change-functions #'riting-assistant--after-change nil t)
        ;; Warm up the model in the background so it's loaded by the time we need it
        (riting-assistant--warmup)
        (message "riting-assistant: ON  (you: %d-%d words, AI: %d-%d words, backend: %s, model: %s)"
                 riting-assistant-user-words-min
                 riting-assistant-user-words-max
                 riting-assistant-ai-words-min
                 riting-assistant-ai-words-max
                 riting-assistant-backend
                 (riting-assistant--active-model)))
    (when (and riting-assistant--stream-proc
               (process-live-p riting-assistant--stream-proc))
      (delete-process riting-assistant--stream-proc))
    (setq buffer-read-only nil)
    (remove-hook 'after-change-functions #'riting-assistant--after-change t)
    (message "riting-assistant: OFF")))

(provide 'riting-assistant)

;;; riting-assistant.el ends here
