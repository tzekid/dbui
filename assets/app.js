(() => {
  "use strict";

  const search = document.querySelector("[data-object-search]");
  if (search) {
    search.addEventListener("input", () => {
      const query = search.value.toLocaleLowerCase();
      document.querySelectorAll("[data-object-name]").forEach((item) => {
        item.hidden = !item.hasAttribute("data-current") && !item.dataset.objectName.toLocaleLowerCase().includes(query);
      });
    });
  }

  const staticSqlBlocks = document.querySelectorAll("code[data-sql-static]");
  const queryForm = document.querySelector("form[data-query-form]");
  if (staticSqlBlocks.length === 0 && !queryForm) return;

  // This list comes from sqlite3_keyword_name() in the vendored SQLite 3.53.4
  // build. Highlighting is lexical only; SQLite remains the parser and source
  // of truth when a statement runs.
  const SQLITE_KEYWORDS = new Set(`
    ABORT ACTION ADD AFTER ALL ALTER ALWAYS ANALYZE AND AS ASC ATTACH AUTOINCREMENT
    BEFORE BEGIN BETWEEN BY CASCADE CASE CAST CHECK COLLATE COLUMN COMMIT
    CONFLICT CONSTRAINT CREATE CROSS CURRENT CURRENT_DATE CURRENT_TIME
    CURRENT_TIMESTAMP DATABASE DEFAULT DEFERRABLE DEFERRED DELETE DESC DETACH
    DISTINCT DO DROP EACH ELSE END ESCAPE EXCEPT EXCLUDE EXCLUSIVE EXISTS
    EXPLAIN FAIL FILTER FIRST FOLLOWING FOR FOREIGN FROM FULL GENERATED GLOB
    GROUP GROUPS HAVING IF IGNORE IMMEDIATE IN INDEX INDEXED INITIALLY INNER
    INSERT INSTEAD INTERSECT INTO IS ISNULL JOIN KEY LAST LEFT LIKE LIMIT MATCH
    MATERIALIZED NATURAL NO NOT NOTHING NOTNULL NULL NULLS OF OFFSET ON OR ORDER
    OTHERS OUTER OVER PARTITION PLAN PRAGMA PRECEDING PRIMARY QUERY RAISE RANGE
    RECURSIVE REFERENCES REGEXP REINDEX RELEASE RENAME REPLACE RESTRICT RETURNING RIGHT
    ROLLBACK ROW ROWS SAVEPOINT SELECT SET TABLE TEMP TEMPORARY THEN TIES TO
    TRANSACTION TRIGGER UNBOUNDED UNION UNIQUE UPDATE USING VACUUM VALUES VIEW
    VIRTUAL WHEN WHERE WINDOW WITH WITHOUT
  `.trim().split(/\s+/));
  const SQLITE_LITERALS = new Set(["NULL", "TRUE", "FALSE", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP"]);
  const MAX_HIGHLIGHT_CHARACTERS = 65536;
  const MAX_HIGHLIGHT_SPANS = 4096;
  const SCRATCH_SAVE_DELAY_MS = 500;

  const isAsciiLetter = (code) => (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  const isDigit = (code) => code >= 48 && code <= 57;
  const isHexDigit = (code) => isDigit(code) || (code >= 65 && code <= 70) || (code >= 97 && code <= 102);
  const isIdentifierStart = (code) => isAsciiLetter(code) || code === 95 || code >= 128;
  const isIdentifierContinue = (code) => isIdentifierStart(code) || isDigit(code) || code === 36;
  const isSpace = (code) => code === 32 || (code >= 9 && code <= 13) || code === 0xfeff;

  function quotedEnd(source, start, quote) {
    let index = start + 1;
    while (index < source.length) {
      if (source[index] !== quote) {
        index += 1;
      } else if (source[index + 1] === quote) {
        index += 2;
      } else {
        return index + 1;
      }
    }
    return source.length;
  }

  function digitsEnd(source, start, isAcceptedDigit) {
    let index = start;
    while (index < source.length) {
      if (isAcceptedDigit(source.charCodeAt(index))) {
        index += 1;
      } else if (
        source[index] === "_" &&
        index > start &&
        isAcceptedDigit(source.charCodeAt(index - 1)) &&
        isAcceptedDigit(source.charCodeAt(index + 1))
      ) {
        index += 1;
      } else {
        break;
      }
    }
    return index;
  }

  function numberEnd(source, start) {
    if (
      source[start] === "0" &&
      (source[start + 1] === "x" || source[start + 1] === "X") &&
      isHexDigit(source.charCodeAt(start + 2))
    ) {
      return digitsEnd(source, start + 2, isHexDigit);
    }

    let index;
    if (source[start] === ".") {
      index = digitsEnd(source, start + 1, isDigit);
    } else {
      index = digitsEnd(source, start, isDigit);
      if (source[index] === ".") index = digitsEnd(source, index + 1, isDigit);
    }
    if (
      (source[index] === "e" || source[index] === "E") &&
      (
        isDigit(source.charCodeAt(index + 1)) ||
        ((source[index + 1] === "+" || source[index + 1] === "-") && isDigit(source.charCodeAt(index + 2)))
      )
    ) {
      index = digitsEnd(source, index + (source[index + 1] === "+" || source[index + 1] === "-" ? 2 : 1), isDigit);
    }
    return index;
  }

  function parameterEnd(source, start) {
    if (source[start] === "?") {
      let index = start + 1;
      while (isDigit(source.charCodeAt(index))) index += 1;
      return index;
    }

    let index = start + 1;
    if (!isIdentifierContinue(source.charCodeAt(index))) return start + 1;
    while (isIdentifierContinue(source.charCodeAt(index))) index += 1;
    while (source[index] === ":" && source[index + 1] === ":" && isIdentifierContinue(source.charCodeAt(index + 2))) {
      index += 2;
      while (isIdentifierContinue(source.charCodeAt(index))) index += 1;
    }
    if (source[start] === "$" && source[index] === "(") {
      index += 1;
      while (index < source.length && source[index] !== ")" && !isSpace(source.charCodeAt(index))) index += 1;
      if (source[index] === ")") index += 1;
    }
    return index;
  }

  function tokenizeSqlite(source) {
    const ranges = [];
    let index = 0;
    let previousWord = null;
    let truncated = false;

    function add(start, end, kind) {
      if (ranges.length === MAX_HIGHLIGHT_SPANS) {
        truncated = true;
        return false;
      }
      ranges.push({ start, end, kind });
      return true;
    }

    while (index < source.length) {
      const start = index;
      const code = source.charCodeAt(index);

      if (isSpace(code)) {
        index += 1;
        while (isSpace(source.charCodeAt(index))) index += 1;
        continue;
      }

      if (source[index] === "-" && source[index + 1] === "-") {
        index += 2;
        while (index < source.length && source[index] !== "\n") index += 1;
        if (!add(start, index, "comment")) break;
        continue;
      }
      if (source[index] === "/" && source[index + 1] === "*") {
        const close = source.indexOf("*/", index + 2);
        index = close === -1 ? source.length : close + 2;
        if (!add(start, index, "comment")) break;
        continue;
      }

      if ((source[index] === "x" || source[index] === "X") && source[index + 1] === "'") {
        index = quotedEnd(source, index + 1, "'");
        previousWord = null;
        if (!add(start, index, "blob")) break;
        continue;
      }
      if (source[index] === "'") {
        index = quotedEnd(source, index, "'");
        previousWord = null;
        if (!add(start, index, "string")) break;
        continue;
      }
      if (source[index] === "\"" || source[index] === "`") {
        index = quotedEnd(source, index, source[index]);
        previousWord = null;
        if (!add(start, index, "quoted-identifier")) break;
        continue;
      }
      if (source[index] === "[") {
        const close = source.indexOf("]", index + 1);
        index = close === -1 ? source.length : close + 1;
        previousWord = null;
        if (!add(start, index, "quoted-identifier")) break;
        continue;
      }

      if (source[index] === "?" || source[index] === "$" || source[index] === ":" || source[index] === "@" || source[index] === "#") {
        index = parameterEnd(source, index);
        previousWord = null;
        if (index > start + 1 || source[start] === "?") {
          if (!add(start, index, "parameter")) break;
        }
        continue;
      }

      if (isDigit(code) || (source[index] === "." && isDigit(source.charCodeAt(index + 1)))) {
        index = numberEnd(source, index);
        previousWord = null;
        if (!add(start, index, "number")) break;
        continue;
      }

      if (isIdentifierStart(code)) {
        index += 1;
        let asciiOnly = code < 128;
        while (isIdentifierContinue(source.charCodeAt(index))) {
          if (source.charCodeAt(index) >= 128) asciiOnly = false;
          index += 1;
        }
        const word = asciiOnly ? source.slice(start, index).toUpperCase() : null;
        let kind = null;
        if (word && SQLITE_LITERALS.has(word)) kind = "literal";
        else if (word && (SQLITE_KEYWORDS.has(word) || word === "STRICT" || (word === "ROWID" && previousWord === "WITHOUT"))) kind = "keyword";
        previousWord = word;
        if (kind && !add(start, index, kind)) break;
        continue;
      }

      previousWord = null;
      index += 1;
    }

    return { ranges, truncated };
  }

  function renderHighlightedSql(source, target, executionRange = null) {
    const highlightedSource = source.length > MAX_HIGHLIGHT_CHARACTERS ? source.slice(0, MAX_HIGHLIGHT_CHARACTERS) : source;
    const tokens = tokenizeSqlite(highlightedSource);
    if (highlightedSource.length !== source.length) tokens.truncated = true;
    const fragment = document.createDocumentFragment();

    function appendSegment(start, end, kind = null) {
      if (start >= end) return;
      const cuts = [start];
      if (executionRange?.start > start && executionRange.start < end) cuts.push(executionRange.start);
      if (executionRange?.end > start && executionRange.end < end) cuts.push(executionRange.end);
      cuts.push(end);
      cuts.sort((left, right) => left - right);
      for (let index = 0; index + 1 < cuts.length; index += 1) {
        const pieceStart = cuts[index];
        const pieceEnd = cuts[index + 1];
        const inExecutionRange = executionRange && pieceStart < executionRange.end && pieceEnd > executionRange.start;
        if (!kind && !inExecutionRange) {
          fragment.append(document.createTextNode(source.slice(pieceStart, pieceEnd)));
          continue;
        }
        const span = document.createElement("span");
        if (kind) span.classList.add("sql-token", `sql-token--${kind}`);
        if (inExecutionRange) span.classList.add("sql-execution-range");
        span.textContent = source.slice(pieceStart, pieceEnd);
        fragment.append(span);
      }
    }

    let cursor = 0;
    for (const token of tokens.ranges) {
      appendSegment(cursor, token.start);
      appendSegment(token.start, token.end, token.kind);
      cursor = token.end;
    }
    appendSegment(cursor, source.length);
    target.replaceChildren(fragment);
    return tokens.truncated;
  }

  staticSqlBlocks.forEach((code) => {
    try {
      renderHighlightedSql(code.textContent, code);
    } catch (_error) {
      // The server-rendered, escaped SQL remains intact when enhancement fails.
    }
  });

  const form = queryForm;
  if (!form) return;

  const editor = form.querySelector("[data-sql]");
  const runButton = form.querySelector("[data-run-button]");
  const saveButton = document.querySelector("[data-save-button]");
  const saveState = document.querySelector("[data-save-state]");
  const responseRegion = document.querySelector("[data-query-response]");
  const scopeField = form.querySelector("[data-query-scope]");
  const selectionStartField = form.querySelector("[data-selection-start]");
  const selectionEndField = form.querySelector("[data-selection-end]");
  const cursorField = form.querySelector("[data-cursor-byte]");
  const scopeLabel = form.querySelector("[data-query-scope-label]");
  const revisionField = form.querySelector("[data-base-revision]");
  const resolveUrl = form.dataset.queryResolve;
  const fileField = form.elements.namedItem("file");
  const scratchField = form.elements.namedItem("scratch");
  const writeCheckbox = form.elements.namedItem("confirm_write");
  const sqlEditor = form.querySelector("[data-sql-editor]");
  const highlightLayer = sqlEditor?.querySelector("[data-sql-highlight]");
  const highlightCode = highlightLayer?.querySelector("code");
  const highlightStatus = form.querySelector("[data-sql-highlight-status]");
  const encoder = new TextEncoder();
  const persistentScratch = Boolean(scratchField && saveButton);
  const scratchRecoveryKey = persistentScratch && form.dataset.databaseId ? `dbui:scratch:${form.dataset.databaseId}` : null;
  const fileConflict = runButton.disabled;
  let dirty = Boolean(saveState?.hasAttribute("data-initial-dirty")) || (!fileField && !scratchField && editor.value.length > 0);
  let busy = false;
  let pendingConfirmation = null;
  let editGeneration = 0;
  let scratchSaveTimer = null;
  let scratchSavePromise = null;
  let scratchConflict = persistentScratch && fileConflict;
  let scratchRecoveryValue = null;
  let createAfterSave = false;
  let executionRange = null;
  let executionRangeKey = null;
  let statementResolveTimer = null;
  let statementResolvePromise = null;
  let statementResolvePromiseKey = null;
  let scheduleSqlHighlight = () => {};

  function installSqlHighlighting() {
    if (!sqlEditor || !highlightLayer || !highlightCode || !highlightStatus) return;
    let frame = null;
    let enabled = true;

    function syncScroll() {
      highlightLayer.scrollTop = Math.max(0, editor.scrollTop);
      highlightLayer.scrollLeft = Math.max(0, editor.scrollLeft);
    }

    function disable() {
      enabled = false;
      if (frame !== null) cancelAnimationFrame(frame);
      frame = null;
      sqlEditor.classList.remove("sql-editor--highlighted");
      highlightStatus.hidden = true;
    }

    function paint() {
      frame = null;
      if (!enabled) return;
      try {
        const source = editor.value;
        highlightStatus.hidden = !renderHighlightedSql(source, highlightCode, executionRange);
        syncScroll();
        sqlEditor.classList.add("sql-editor--highlighted");
      } catch (_error) {
        disable();
      }
    }

    function schedule() {
      if (!enabled || frame !== null) return;
      frame = requestAnimationFrame(paint);
    }

    editor.addEventListener("input", schedule);
    editor.addEventListener("scroll", syncScroll, { passive: true });
    window.addEventListener("pageshow", schedule);
    scheduleSqlHighlight = schedule;
    paint();
  }

  installSqlHighlighting();

  const byteOffset = (index) => encoder.encode(editor.value.slice(0, index)).length;
  const lineAt = (index) => editor.value.slice(0, index).split("\n").length;
  const editorScopeKey = () => `${editGeneration}:${editor.selectionStart}:${editor.selectionEnd}`;
  const scopeKey = () => [scopeField.value, selectionStartField.value, selectionEndField.value, cursorField.value].join(":");

  function characterOffset(byte) {
    if (!Number.isSafeInteger(byte) || byte < 0) return null;
    let currentByte = 0;
    let currentCharacter = 0;
    for (const character of editor.value) {
      if (currentByte === byte) return currentCharacter;
      const codePoint = character.codePointAt(0);
      currentByte += codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
      currentCharacter += character.length;
      if (currentByte > byte) return null;
    }
    return currentByte === byte ? currentCharacter : null;
  }

  function lineRangeLabel(firstLine, lastLine) {
    return firstLine === lastLine ? `Line ${firstLine}` : `Lines ${firstLine}–${lastLine}`;
  }

  function clearStatementResolveTimer() {
    if (statementResolveTimer === null) return;
    clearTimeout(statementResolveTimer);
    statementResolveTimer = null;
  }

  function updateRunAvailability() {
    const rangeReady = executionRange && executionRangeKey === editorScopeKey();
    runButton.disabled = busy || fileConflict || scratchConflict || !rangeReady;
  }

  function setExecutionRange(range, key) {
    executionRange = range;
    executionRangeKey = range ? key : null;
    scheduleSqlHighlight();
    updateRunAvailability();
  }

  function applyExecutionRange(range, key, selected) {
    scopeField.value = "selection";
    selectionStartField.value = String(range.startByte);
    selectionEndField.value = String(range.endByte);
    cursorField.value = String(byteOffset(editor.selectionStart));
    setExecutionRange(range, key);
    runButton.textContent = writeCheckbox ? "Confirm and run write" : selected ? "Run selection" : "Run current statement";
    scopeLabel.textContent = selected
      ? lineRangeLabel(range.lineStart, range.lineEnd)
      : `Current statement · ${lineRangeLabel(range.lineStart, range.lineEnd).toLocaleLowerCase()}`;
  }

  function showUnresolvedStatement(message, key) {
    if (key !== editorScopeKey() || editor.selectionStart !== editor.selectionEnd) return;
    const cursor = byteOffset(editor.selectionStart);
    scopeField.value = "current";
    selectionStartField.value = String(cursor);
    selectionEndField.value = String(cursor);
    cursorField.value = String(cursor);
    setExecutionRange(null, null);
    runButton.textContent = writeCheckbox ? "Confirm and run write" : "Run current statement";
    scopeLabel.textContent = message;
  }

  async function resolveCurrentStatement(key) {
    if (!resolveUrl) {
      showUnresolvedStatement("Current statement preview unavailable · select SQL to run", key);
      return false;
    }
    if (statementResolvePromise && statementResolvePromiseKey === key) return statementResolvePromise;
    const cursor = byteOffset(editor.selectionStart);
    const request = (async () => {
      try {
        const response = await fetch(resolveUrl, {
          method: "POST",
          body: encodedForm({
            fragment: null,
            confirm_write: null,
            scope: "current",
            selection_start_byte: "0",
            selection_end_byte: "0",
            cursor_byte: String(cursor),
          }),
        });
        const source = (await response.text()).trim();
        if (key !== editorScopeKey() || editor.selectionStart !== editor.selectionEnd) return false;
        if (!response.ok) {
          const message = source && !source.startsWith("<") ? source.slice(0, 180) : "Current statement preview unavailable · select SQL to run";
          showUnresolvedStatement(message, key);
          return false;
        }
        if (source === "none") {
          showUnresolvedStatement("No statement at caret", key);
          return false;
        }
        const match = /^range (\d+) (\d+) (\d+) (\d+)$/.exec(source);
        if (!match) {
          showUnresolvedStatement("Current statement preview unavailable · select SQL to run", key);
          return false;
        }
        const startByte = Number(match[1]);
        const endByte = Number(match[2]);
        const lineStart = Number(match[3]);
        const lineEnd = Number(match[4]);
        const start = characterOffset(startByte);
        const end = characterOffset(endByte);
        if (start === null || end === null || start >= end || lineStart < 1 || lineEnd < lineStart) {
          showUnresolvedStatement("Current statement preview unavailable · select SQL to run", key);
          return false;
        }
        applyExecutionRange({ start, end, startByte, endByte, lineStart, lineEnd }, key, false);
        return true;
      } catch (_error) {
        showUnresolvedStatement("Current statement preview unavailable · select SQL to run", key);
        return false;
      }
    })();
    statementResolvePromise = request;
    statementResolvePromiseKey = key;
    const resolved = await request;
    if (statementResolvePromise === request) {
      statementResolvePromise = null;
      statementResolvePromiseKey = null;
    }
    return resolved;
  }

  function scheduleStatementResolution(key) {
    clearStatementResolveTimer();
    statementResolveTimer = setTimeout(() => {
      statementResolveTimer = null;
      void resolveCurrentStatement(key);
    }, 140);
  }

  function updateScope() {
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    const key = editorScopeKey();
    const selected = start !== end;
    if (selected) {
      clearStatementResolveTimer();
      const firstLine = lineAt(start);
      const lastLine = Math.max(firstLine, lineAt(end) - (editor.value[end - 1] === "\n" ? 1 : 0));
      applyExecutionRange({
        start,
        end,
        startByte: byteOffset(start),
        endByte: byteOffset(end),
        lineStart: firstLine,
        lineEnd: lastLine,
      }, key, true);
    } else if (executionRange && executionRangeKey === key) {
      applyExecutionRange(executionRange, key, false);
    } else {
      const cursor = byteOffset(start);
      scopeField.value = "current";
      selectionStartField.value = String(cursor);
      selectionEndField.value = String(cursor);
      cursorField.value = String(cursor);
      setExecutionRange(null, null);
      runButton.textContent = writeCheckbox ? "Confirm and run write" : "Run current statement";
      scopeLabel.textContent = `Locating statement at line ${lineAt(start)}…`;
      scheduleStatementResolution(key);
    }
    if (pendingConfirmation && pendingConfirmation !== scopeKey()) clearWriteConfirmation();
  }

  async function prepareExecutionScope() {
    updateScope();
    if (executionRange && executionRangeKey === editorScopeKey()) return true;
    const key = editorScopeKey();
    clearStatementResolveTimer();
    return resolveCurrentStatement(key);
  }

  function markResultStale() {
    const result = responseRegion?.querySelector("[data-query-result]");
    if (!result || result.classList.contains("query-result--stale")) return;
    result.classList.add("query-result--stale");
    const label = document.createElement("span");
    label.className = "query-result-stale";
    label.textContent = "Result from previous source";
    result.querySelector("header")?.append(label);
  }

  function clearWriteConfirmation() {
    if (responseRegion?.querySelector("[data-confirm-write]")) responseRegion.replaceChildren();
    pendingConfirmation = null;
  }

  function setDirty() {
    dirty = true;
    if (saveState) saveState.textContent = fileField || persistentScratch ? "Unsaved changes" : "Unsaved scratch";
    clearWriteConfirmation();
    markResultStale();
  }

  function setBusy(active, label) {
    busy = active;
    updateRunAvailability();
    if (saveButton) saveButton.disabled = active;
    if (active && label && saveState) saveState.textContent = label;
  }

  function updateRevision(response) {
    if (!revisionField) return;
    const etag = response.headers.get("etag");
    if (!etag) return;
    revisionField.value = etag.replace(/^W\//, "").replace(/^"|"$/g, "");
  }

  function acknowledgeSave(response, generation) {
    updateRevision(response);
    dirty = generation !== editGeneration;
    if (persistentScratch) {
      if (dirty) storeScratchRecovery(true);
      else clearScratchRecovery();
    }
    if (saveState) saveState.textContent = dirty ? "Unsaved changes" : persistentScratch ? "Saved on server" : "Saved";
  }

  function encodedForm(extra) {
    const values = new URLSearchParams(new FormData(form));
    for (const [name, value] of Object.entries(extra)) {
      if (value == null) values.delete(name);
      else values.set(name, value);
    }
    return values;
  }

  function clearScratchRecovery() {
    if (!scratchRecoveryKey) return;
    try {
      if (localStorage.getItem(scratchRecoveryKey) === scratchRecoveryValue) {
        localStorage.removeItem(scratchRecoveryKey);
        scratchRecoveryValue = null;
      }
    } catch (_error) {
      // Server persistence remains authoritative when browser storage is unavailable.
    }
  }

  function storeScratchRecovery(onlyIfOwned = false) {
    if (!scratchRecoveryKey) return;
    try {
      if (onlyIfOwned && localStorage.getItem(scratchRecoveryKey) !== scratchRecoveryValue) return;
      const encoded = JSON.stringify({
        version: 1,
        revision: revisionField?.value || "",
        source: editor.value,
      });
      localStorage.setItem(scratchRecoveryKey, encoded);
      scratchRecoveryValue = encoded;
    } catch (_error) {
      // Keepalive server saves remain available when browser storage is disabled.
    }
  }

  function restoreScratchRecovery() {
    if (!scratchRecoveryKey) return;
    let recovery;
    try {
      const encoded = localStorage.getItem(scratchRecoveryKey);
      if (!encoded) return;
      scratchRecoveryValue = encoded;
      recovery = JSON.parse(encoded);
    } catch (_error) {
      clearScratchRecovery();
      return;
    }
    if (
      recovery?.version !== 1 ||
      typeof recovery.revision !== "string" ||
      typeof recovery.source !== "string" ||
      (recovery.revision !== "" && !/^[0-9a-f]{64}$/.test(recovery.revision))
    ) {
      clearScratchRecovery();
      return;
    }
    if (recovery.source === editor.value) {
      if (!dirty) clearScratchRecovery();
      return;
    }

    editor.value = recovery.source;
    editGeneration += 1;
    dirty = true;
    const serverRevision = revisionField?.value || "";
    if (recovery.revision === serverRevision) {
      if (saveState) saveState.textContent = "Recovered unsaved draft";
      scheduleScratchSave();
      return;
    }

    scratchConflict = true;
    if (saveState) saveState.textContent = "Browser recovery";
    updateRunAvailability();
    if (responseRegion) {
      const notice = document.createElement("section");
      notice.className = "notice notice--warning";
      const heading = document.createElement("strong");
      heading.textContent = "Recovered a browser draft.";
      const reload = document.createElement("a");
      reload.className = "button";
      reload.href = location.href;
      reload.textContent = "Use server Scratch";
      reload.addEventListener("click", clearScratchRecovery);
      notice.append(heading, " The server copy changed too. Save this buffer as a named file, or ", reload, ".");
      responseRegion.replaceChildren(notice);
    }
  }

  function replaceFullPage(source, generation) {
    if (generation !== editGeneration) {
      if (responseRegion) responseRegion.textContent = "The response belongs to an older edit. Your newer editor buffer is unchanged. Copy this buffer before reloading.";
      return;
    }
    dirty = false;
    document.open();
    document.write(source);
    document.close();
  }

  async function saveFile() {
    if (!saveButton || busy) return !saveButton;
    setBusy(true, "Saving…");
    const generation = editGeneration;
    try {
      const response = await fetch(saveButton.formAction, {
        method: "POST",
        body: encodedForm({ fragment: "save-state", confirm_write: null }),
      });
      if (response.ok && response.headers.has("etag")) {
        acknowledgeSave(response, generation);
        return !dirty;
      }
      const source = await response.text();
      if (/^\s*<!doctype html>/i.test(source)) replaceFullPage(source, generation);
      else if (responseRegion) responseRegion.innerHTML = source;
      if (saveState) saveState.textContent = response.status === 409 ? "Conflict" : "Save failed";
      return false;
    } catch (_error) {
      if (saveState) saveState.textContent = "Save failed";
      if (responseRegion) responseRegion.textContent = "The save request could not reach dbui. Your editor buffer is unchanged.";
      return false;
    } finally {
      setBusy(false);
    }
  }

  function clearScratchSaveTimer() {
    if (scratchSaveTimer === null) return;
    clearTimeout(scratchSaveTimer);
    scratchSaveTimer = null;
  }

  function scheduleScratchSave() {
    if (!persistentScratch || scratchConflict || busy) return;
    clearScratchSaveTimer();
    scratchSaveTimer = setTimeout(() => {
      scratchSaveTimer = null;
      void saveScratch();
    }, SCRATCH_SAVE_DELAY_MS);
  }

  async function saveScratch(keepalive = false) {
    if (!persistentScratch || scratchConflict || busy) return false;
    if (scratchSavePromise) return scratchSavePromise;
    clearScratchSaveTimer();
    const generation = editGeneration;
    if (saveState) saveState.textContent = "Saving…";
    const request = (async () => {
      try {
        const response = await fetch(saveButton.formAction, {
          method: "POST",
          body: encodedForm({ fragment: "save-state", confirm_write: null }),
          keepalive,
        });
        if (response.ok && response.headers.has("etag")) {
          acknowledgeSave(response, generation);
          return true;
        }
        await response.text();
        scratchConflict = response.status === 409;
        updateRunAvailability();
        if (saveState) saveState.textContent = scratchConflict ? "Conflict" : "Autosave failed";
        if (responseRegion) {
          responseRegion.textContent = scratchConflict
            ? "Scratch changed elsewhere. Reload Scratch or save this buffer as a named file."
            : "Scratch could not be saved. Your editor buffer is unchanged.";
        }
        return false;
      } catch (_error) {
        if (saveState) saveState.textContent = "Autosave failed";
        if (responseRegion) responseRegion.textContent = "The save request could not reach dbui. Your editor buffer is unchanged.";
        return false;
      }
    })();
    scratchSavePromise = request;
    const saved = await request;
    scratchSavePromise = null;
    if (!scratchConflict && dirty && generation !== editGeneration) scheduleScratchSave();
    return saved;
  }

  async function flushScratch(keepalive = false) {
    clearScratchSaveTimer();
    if (scratchSavePromise) await scratchSavePromise;
    if (!dirty || scratchConflict) return !dirty;
    return saveScratch(keepalive);
  }

  async function waitForScratchSave() {
    clearScratchSaveTimer();
    if (scratchSavePromise) await scratchSavePromise;
    clearScratchSaveTimer();
  }

  async function runQuery(confirmed = false, reuseScope = false) {
    if (busy || fileConflict || scratchConflict) return;
    if (fileField && dirty && !(await saveFile())) return;
    if (persistentScratch) await waitForScratchSave();
    if (scratchConflict) return;
    if (!reuseScope && !(await prepareExecutionScope())) return;
    if (busy || scratchConflict) return;
    setBusy(true, "Running…");
    const generation = editGeneration;
    const requestedScope = scopeKey();
    const originalLabel = runButton.textContent;
    runButton.textContent = "Running…";
    try {
      const response = await fetch(form.action, {
        method: "POST",
        body: encodedForm({ fragment: "query-result", confirm_write: confirmed || writeCheckbox?.checked ? "1" : null }),
      });
      const source = await response.text();
      if (/^\s*<!doctype html>/i.test(source)) {
        replaceFullPage(source, generation);
        return;
      }
      if (responseRegion) responseRegion.innerHTML = source;
      pendingConfirmation = responseRegion?.querySelector("[data-confirm-write]") ? requestedScope : null;
      if (persistentScratch && response.headers.has("etag")) acknowledgeSave(response, generation);
      else updateRevision(response);
      if (generation !== editGeneration || requestedScope !== scopeKey()) {
        clearWriteConfirmation();
        markResultStale();
      }
    } catch (_error) {
      if (responseRegion) responseRegion.textContent = "The query request could not reach dbui. No result was received.";
    } finally {
      setBusy(false);
      runButton.textContent = originalLabel;
      updateScope();
      if (persistentScratch && dirty) scheduleScratchSave();
    }
  }

  editor.addEventListener("input", () => {
    if (writeCheckbox) writeCheckbox.checked = false;
    editGeneration += 1;
    setDirty();
    storeScratchRecovery();
    scheduleScratchSave();
    updateScope();
  });
  editor.addEventListener("select", () => {
    if (writeCheckbox) writeCheckbox.checked = false;
    clearWriteConfirmation();
    updateScope();
  });
  editor.addEventListener("keyup", updateScope);
  editor.addEventListener("mouseup", updateScope);
  document.addEventListener("selectionchange", () => {
    if (document.activeElement === editor) updateScope();
  });

  form.addEventListener("submit", (event) => {
    const submitter = event.submitter;
    const action = submitter?.formAction || form.action;
    if (action.endsWith("/query/file/create")) {
      if (createAfterSave) {
        createAfterSave = false;
        dirty = false;
        return;
      }
      if (persistentScratch) {
        clearScratchSaveTimer();
        if (scratchSavePromise) {
          event.preventDefault();
          void (async () => {
            await waitForScratchSave();
            createAfterSave = true;
            form.requestSubmit(submitter);
            if (createAfterSave) createAfterSave = false;
          })();
          return;
        }
      }
      dirty = false;
      return;
    }
    event.preventDefault();
    if (submitter?.hasAttribute("data-save-button")) {
      if (persistentScratch) void flushScratch();
      else void saveFile();
    }
    else void runQuery(Boolean(writeCheckbox?.checked), Boolean(writeCheckbox));
  });

  responseRegion?.addEventListener("click", (event) => {
    const button = event.target.closest?.("[data-confirm-write]");
    if (!button) return;
    event.preventDefault();
    if (!pendingConfirmation || pendingConfirmation !== scopeKey()) {
      clearWriteConfirmation();
      return;
    }
    void runQuery(true, true);
  });

  document.addEventListener("keydown", (event) => {
    if (!(event.ctrlKey || event.metaKey) || event.altKey) return;
    if (!event.target.closest?.("form[data-query-form]")) return;
    if (event.key === "Enter") {
      event.preventDefault();
      void runQuery(Boolean(writeCheckbox?.checked), Boolean(writeCheckbox));
    } else if (event.key.toLocaleLowerCase() === "s") {
      event.preventDefault();
      if (persistentScratch) void flushScratch();
      else if (saveButton) void saveFile();
      else document.querySelector("input[name=new_name][form=query-editor]")?.focus();
    }
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden" && persistentScratch && dirty && !scratchConflict) void flushScratch(true);
  });

  window.addEventListener("pagehide", () => {
    if (persistentScratch && dirty && !scratchConflict) void flushScratch(true);
  });

  window.addEventListener("beforeunload", (event) => {
    if (!dirty) return;
    if (persistentScratch && !scratchConflict) {
      void flushScratch(true);
      return;
    }
    event.preventDefault();
    event.returnValue = "";
  });

  restoreScratchRecovery();
  if (persistentScratch && dirty && !scratchConflict) {
    storeScratchRecovery();
    scheduleScratchSave();
  }
  updateScope();
})();
