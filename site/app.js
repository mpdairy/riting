(function () {
  'use strict';

  var CONFIG = {
    userWordsMin: 15,
    userWordsMax: 45,
    aiWordsMin: 10,
    aiWordsMax: 20,
    proxyUrl: '/api/chat',
    directGroqUrl: 'https://api.groq.com/openai/v1/chat/completions',
    model: 'llama-3.1-8b-instant',
    storyWordLimit: 2000,
    originality: 5,
    systemPrompt:
      'You are a creative writing collaborator. Continue the story or text ' +
      'seamlessly from where it left off. Write ONLY the continuation text ' +
      '\u2014 no commentary, no numbering, no bullet points, no labels, no ' +
      'meta-text. Match the existing style and tone exactly.',
  };

  var state = {
    wordCount: 0,
    prevWordCount: 0,
    generating: false,
    userTarget: 20,
    aiTarget: 8,
    abortController: null,
    currentTab: 1,
  };

  // --- DOM ---

  var editor = document.getElementById('editor');
  var statusEl = document.getElementById('status');
  var settingsBtn = document.getElementById('settings-btn');
  var modal = document.getElementById('modal');
  var modalBackdrop = document.getElementById('modal-backdrop');
  var keyInput = document.getElementById('key-input');
  var userMinInput = document.getElementById('user-min');
  var userMaxInput = document.getElementById('user-max');
  var aiMinInput = document.getElementById('ai-min');
  var aiMaxInput = document.getElementById('ai-max');
  var originalityInput = document.getElementById('originality');
  var saveBtn = document.getElementById('save-btn');
  var cancelBtn = document.getElementById('cancel-btn');

  // --- Helpers ---

  function rand(min, max) {
    return min + Math.floor(Math.random() * (max - min + 1));
  }

  function rollTargets() {
    state.userTarget = rand(CONFIG.userWordsMin, CONFIG.userWordsMax);
    state.aiTarget = rand(CONFIG.aiWordsMin, CONFIG.aiWordsMax);
  }

  function countWords(text) {
    var t = text.trim();
    return t ? t.split(/\s+/).length : 0;
  }

  function getTemperature() {
    return 0.6 + (CONFIG.originality * 0.08);
  }

  function getSystemPrompt() {
    var base = CONFIG.systemPrompt;
    if (CONFIG.originality <= 3) {
      return base + ' Write in a familiar, comfortable style.';
    } else if (CONFIG.originality >= 7) {
      return base +
        ' Be bold, surprising, and original. Avoid cliches and predictable phrases.' +
        ' Take the story in unexpected directions.';
    }
    return base;
  }

  function getApiKey() {
    return localStorage.getItem('riting-groq-key');
  }

  function setStatus(msg, isGenerating) {
    statusEl.textContent = msg || '';
    if (isGenerating) {
      statusEl.classList.add('generating');
    } else {
      statusEl.classList.remove('generating');
    }
  }

  // --- Auto-save ---

  var saveTimer;

  function draftKey(tab) {
    return 'riting-draft-' + tab;
  }

  function scheduleSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      localStorage.setItem(draftKey(state.currentTab), editor.value);
      updateTabIndicators();
    }, 1000);
  }

  function saveDraftNow() {
    clearTimeout(saveTimer);
    localStorage.setItem(draftKey(state.currentTab), editor.value);
  }

  function restoreDraft() {
    var draft = localStorage.getItem(draftKey(state.currentTab));
    editor.value = draft || '';
    state.prevWordCount = countWords(editor.value);
  }

  // --- Tabs ---

  var tabButtons = document.querySelectorAll('.tab');

  function updateTabIndicators() {
    for (var i = 0; i < tabButtons.length; i++) {
      var btn = tabButtons[i];
      var tab = parseInt(btn.getAttribute('data-tab'), 10);
      var draft = localStorage.getItem(draftKey(tab));
      if (draft && draft.trim().length > 0) {
        btn.classList.add('has-content');
      } else {
        btn.classList.remove('has-content');
      }
      if (tab === state.currentTab) {
        btn.classList.add('active');
      } else {
        btn.classList.remove('active');
      }
    }
  }

  function switchTab(tab) {
    if (tab === state.currentTab || state.generating) return;
    saveDraftNow();
    state.currentTab = tab;
    localStorage.setItem('riting-current-tab', tab);
    restoreDraft();
    state.wordCount = 0;
    rollTargets();
    updateTabIndicators();
    setStatus('');
    editor.focus();
  }

  for (var i = 0; i < tabButtons.length; i++) {
    tabButtons[i].addEventListener('click', function () {
      switchTab(parseInt(this.getAttribute('data-tab'), 10));
    });
  }

  // --- Settings persistence ---

  function loadSettings() {
    var saved = localStorage.getItem('riting-settings');
    if (saved) {
      try {
        var s = JSON.parse(saved);
        if (s.userWordsMin) CONFIG.userWordsMin = s.userWordsMin;
        if (s.userWordsMax) CONFIG.userWordsMax = s.userWordsMax;
        if (s.aiWordsMin) CONFIG.aiWordsMin = s.aiWordsMin;
        if (s.aiWordsMax) CONFIG.aiWordsMax = s.aiWordsMax;
        if (s.originality != null) CONFIG.originality = s.originality;
      } catch (_) {}
    }
  }

  function saveSettings() {
    localStorage.setItem('riting-settings', JSON.stringify({
      userWordsMin: CONFIG.userWordsMin,
      userWordsMax: CONFIG.userWordsMax,
      aiWordsMin: CONFIG.aiWordsMin,
      aiWordsMax: CONFIG.aiWordsMax,
      originality: CONFIG.originality,
    }));
  }

  // --- Settings modal ---

  function showSettings() {
    keyInput.value = getApiKey() || '';
    userMinInput.value = CONFIG.userWordsMin;
    userMaxInput.value = CONFIG.userWordsMax;
    aiMinInput.value = CONFIG.aiWordsMin;
    aiMaxInput.value = CONFIG.aiWordsMax;
    originalityInput.value = CONFIG.originality;
    modal.classList.remove('hidden');
    userMinInput.focus();
  }

  function hideSettings() {
    modal.classList.add('hidden');
    editor.focus();
  }

  settingsBtn.addEventListener('click', showSettings);
  modalBackdrop.addEventListener('click', hideSettings);
  cancelBtn.addEventListener('click', hideSettings);

  saveBtn.addEventListener('click', function () {
    var key = keyInput.value.trim();
    if (key) {
      localStorage.setItem('riting-groq-key', key);
    } else {
      localStorage.removeItem('riting-groq-key');
    }

    var uMin = parseInt(userMinInput.value, 10);
    var uMax = parseInt(userMaxInput.value, 10);
    var aMin = parseInt(aiMinInput.value, 10);
    var aMax = parseInt(aiMaxInput.value, 10);

    if (uMin > 0 && uMax > 0 && uMax >= uMin) {
      CONFIG.userWordsMin = uMin;
      CONFIG.userWordsMax = uMax;
    }
    if (aMin > 0 && aMax > 0 && aMax >= aMin) {
      CONFIG.aiWordsMin = aMin;
      CONFIG.aiWordsMax = aMax;
    }

    CONFIG.originality = parseInt(originalityInput.value, 10);

    saveSettings();
    rollTargets();
    hideSettings();
    setStatus('settings saved');
    setTimeout(function () {
      if (!state.generating) setStatus('');
    }, 2000);
  });

  keyInput.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') saveBtn.click();
    if (e.key === 'Escape') hideSettings();
  });

  // --- Block typing during generation ---

  editor.addEventListener('keydown', function (e) {
    if (state.generating) e.preventDefault();
  });

  // --- Word tracking ---

  editor.addEventListener('input', function () {
    if (state.generating) return;
    scheduleSave();

    var cur = countWords(editor.value);
    var delta = cur - state.prevWordCount;
    if (delta > 0) state.wordCount += delta;
    state.prevWordCount = cur;

    if (state.wordCount >= state.userTarget && /\s$/.test(editor.value)) {
      triggerGeneration();
    }
  });

  // --- Blinking robot indicator ---

  var blinkInterval = null;
  var blinkBase = 0;
  var blinkVisible = false;

  function startBlink() {
    blinkBase = editor.value.length;
    blinkVisible = true;
    editor.value += ' \uD83E\uDD16';
    editor.scrollTop = editor.scrollHeight;
    blinkInterval = setInterval(function () {
      if (blinkVisible) {
        editor.value = editor.value.slice(0, blinkBase);
      } else {
        editor.value = editor.value.slice(0, blinkBase) + ' \uD83E\uDD16';
      }
      blinkVisible = !blinkVisible;
      editor.scrollTop = editor.scrollHeight;
    }, 500);
  }

  function stopBlink() {
    clearInterval(blinkInterval);
    blinkInterval = null;
    editor.value = editor.value.slice(0, blinkBase);
  }

  // --- Typewriter effect ---

  function typeOut(text) {
    return new Promise(function (resolve) {
      var chars = text.split('');
      var idx = 0;

      function nextChar() {
        if (idx >= chars.length) {
          resolve();
          return;
        }
        editor.value += chars[idx];
        editor.scrollTop = editor.scrollHeight;
        idx++;

        var delay = 25 + Math.random() * 20;
        if (chars[idx - 1] === ' ') {
          delay += Math.random() * 15;
        }
        if (chars[idx - 1] === '\n') {
          delay += 30 + Math.random() * 30;
        }
        setTimeout(nextChar, delay);
      }

      nextChar();
    });
  }

  // --- Generation ---

  async function triggerGeneration() {
    if (state.generating) return;

    // Check story length limit (skip if using own key)
    var customKey = getApiKey();
    if (!customKey && countWords(editor.value) >= CONFIG.storyWordLimit) {
      setStatus('story hit the ' + CONFIG.storyWordLimit + ' word limit \u2014 start a new tab!');
      return;
    }

    // Use custom key directly against Groq, otherwise use the proxy
    var url = customKey ? CONFIG.directGroqUrl : CONFIG.proxyUrl;
    var headers = { 'Content-Type': 'application/json' };
    if (customKey) {
      headers['Authorization'] = 'Bearer ' + customKey;
    }

    state.generating = true;
    editor.readOnly = true;
    setStatus('AI is typing\u2026', true);

    var fullText = editor.value;

    if (fullText.length > 0 && !/\s$/.test(fullText)) {
      editor.value += ' ';
    }
    var insertStart = editor.value.length;

    startBlink();
    state.abortController = new AbortController();

    try {
      var res = await fetch(url, {
        method: 'POST',
        headers: headers,
        body: JSON.stringify({
          model: CONFIG.model,
          messages: [
            { role: 'system', content: getSystemPrompt() },
            {
              role: 'user',
              content:
                'Continue this text naturally, writing only the next few sentences:\n\n' +
                fullText,
            },
          ],
          stream: true,
          max_tokens: state.aiTarget,
          temperature: getTemperature(),
        }),
        signal: state.abortController.signal,
      });

      if (!res.ok) {
        if (res.status === 401) throw new Error('invalid API key \u2014 check settings');
        if (res.status === 429) throw new Error('slow down \u2014 too many requests');
        if (res.status === 413) throw new Error('story is too long for the free tier');
        throw new Error('API error ' + res.status);
      }

      var reader = res.body.getReader();
      var dec = new TextDecoder();
      var partial = '';
      var accumulated = '';

      reading: while (true) {
        var chunk = await reader.read();
        if (chunk.done) break;

        partial += dec.decode(chunk.value, { stream: true });
        var lines = partial.split('\n');
        partial = lines.pop();

        for (var i = 0; i < lines.length; i++) {
          var line = lines[i];
          if (!line.startsWith('data: ')) continue;
          var data = line.slice(6);
          if (data === '[DONE]') break reading;

          try {
            var resp = JSON.parse(data);
            var token =
              resp.choices &&
              resp.choices[0] &&
              resp.choices[0].delta &&
              resp.choices[0].delta.content;

            if (token) {
              accumulated += token;
            }
          } catch (_) {}
        }
      }
    } catch (err) {
      if (err.name !== 'AbortError') {
        stopBlink();
        setStatus('error: ' + err.message);
        state.generating = false;
        editor.readOnly = false;
        setTimeout(function () { setStatus(''); }, 5000);
        return;
      }
    }

    stopBlink();

    // Drop the last word in case it got cut off mid-token
    var trimmed = accumulated.replace(/\s*\S+\s*$/, '');

    await typeOut(trimmed);

    // Reset
    state.generating = false;
    editor.readOnly = false;
    state.wordCount = 0;
    state.prevWordCount = countWords(editor.value);

    var wrote = countWords(trimmed);
    rollTargets();
    setStatus('AI wrote ' + wrote + ' words \u2014 keep writing!');
    setTimeout(function () {
      if (!state.generating) setStatus('');
    }, 3000);

    editor.focus();
    editor.selectionStart = editor.selectionEnd = editor.value.length;
    scheduleSave();
  }

  // --- Init ---

  loadSettings();
  var savedTab = parseInt(localStorage.getItem('riting-current-tab'), 10);
  if (savedTab >= 1 && savedTab <= 8) state.currentTab = savedTab;
  restoreDraft();
  rollTargets();
  updateTabIndicators();
  editor.focus();
})();
