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

  function renderHighlightedSql(source, target) {
    const highlightedSource = source.length > MAX_HIGHLIGHT_CHARACTERS ? source.slice(0, MAX_HIGHLIGHT_CHARACTERS) : source;
    const tokens = tokenizeSqlite(highlightedSource);
    if (highlightedSource.length !== source.length) tokens.truncated = true;
    const fragment = document.createDocumentFragment();
    let cursor = 0;
    for (const token of tokens.ranges) {
      if (token.start > cursor) fragment.append(document.createTextNode(source.slice(cursor, token.start)));
      const span = document.createElement("span");
      span.className = `sql-token sql-token--${token.kind}`;
      span.textContent = source.slice(token.start, token.end);
      fragment.append(span);
      cursor = token.end;
    }
    if (cursor < source.length) fragment.append(document.createTextNode(source.slice(cursor)));
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
  const fileField = form.elements.namedItem("file");
  const writeCheckbox = form.elements.namedItem("confirm_write");
  const sqlEditor = form.querySelector("[data-sql-editor]");
  const highlightLayer = sqlEditor?.querySelector("[data-sql-highlight]");
  const highlightCode = highlightLayer?.querySelector("code");
  const highlightStatus = form.querySelector("[data-sql-highlight-status]");
  const encoder = new TextEncoder();
  let dirty = (!fileField && editor.value.length > 0) || Boolean(saveState?.hasAttribute("data-initial-dirty"));
  let busy = false;
  let pendingConfirmation = null;

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
        highlightStatus.hidden = !renderHighlightedSql(source, highlightCode);
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
    paint();
  }

  installSqlHighlighting();

  const byteOffset = (index) => encoder.encode(editor.value.slice(0, index)).length;
  const lineAt = (index) => editor.value.slice(0, index).split("\n").length;
  const scopeKey = () => [scopeField.value, selectionStartField.value, selectionEndField.value, cursorField.value].join(":");

  function updateScope() {
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    const selected = start !== end;
    scopeField.value = selected ? "selection" : "current";
    selectionStartField.value = String(byteOffset(start));
    selectionEndField.value = String(byteOffset(end));
    cursorField.value = String(byteOffset(start));
    if (selected) {
      const firstLine = lineAt(start);
      const lastLine = Math.max(firstLine, lineAt(end) - (editor.value[end - 1] === "\n" ? 1 : 0));
      runButton.textContent = writeCheckbox?.checked ? "Confirm and run write" : "Run selection";
      scopeLabel.textContent = firstLine === lastLine ? `Line ${firstLine}` : `Lines ${firstLine}–${lastLine}`;
    } else {
      runButton.textContent = writeCheckbox?.checked ? "Confirm and run write" : "Run current statement";
      scopeLabel.textContent = `Statement at caret · line ${lineAt(start)}`;
    }
    if (pendingConfirmation && pendingConfirmation !== scopeKey()) clearWriteConfirmation();
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
    if (saveState) saveState.textContent = fileField ? "Unsaved changes" : "Unsaved scratch";
    clearWriteConfirmation();
    markResultStale();
  }

  function setBusy(active, label) {
    busy = active;
    runButton.disabled = active;
    if (saveButton) saveButton.disabled = active;
    if (active && label && saveState) saveState.textContent = label;
  }

  function updateRevision(response) {
    if (!revisionField) return;
    const etag = response.headers.get("etag");
    if (!etag) return;
    revisionField.value = etag.replace(/^W\//, "").replace(/^"|"$/g, "");
  }

  function encodedForm(extra) {
    const values = new URLSearchParams(new FormData(form));
    for (const [name, value] of Object.entries(extra)) {
      if (value == null) values.delete(name);
      else values.set(name, value);
    }
    return values;
  }

  function replaceFullPage(source) {
    dirty = false;
    document.open();
    document.write(source);
    document.close();
  }

  async function saveFile() {
    if (!saveButton || busy) return !saveButton;
    setBusy(true, "Saving…");
    try {
      const response = await fetch(saveButton.formAction, {
        method: "POST",
        body: encodedForm({ fragment: "save-state", confirm_write: null }),
      });
      if (response.ok && response.headers.has("etag")) {
        updateRevision(response);
        dirty = false;
        if (saveState) saveState.textContent = "Saved";
        return true;
      }
      const source = await response.text();
      if (/^\s*<!doctype html>/i.test(source)) replaceFullPage(source);
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

  async function runQuery(confirmed = false, reuseScope = false) {
    if (busy || runButton.disabled) return;
    if (fileField && dirty && !(await saveFile())) return;
    if (!reuseScope) updateScope();
    setBusy(true, "Running…");
    const originalLabel = runButton.textContent;
    runButton.textContent = "Running…";
    try {
      const response = await fetch(form.action, {
        method: "POST",
        body: encodedForm({ fragment: "query-result", confirm_write: confirmed || writeCheckbox?.checked ? "1" : null }),
      });
      const source = await response.text();
      if (/^\s*<!doctype html>/i.test(source)) {
        replaceFullPage(source);
        return;
      }
      updateRevision(response);
      if (responseRegion) responseRegion.innerHTML = source;
      pendingConfirmation = responseRegion?.querySelector("[data-confirm-write]") ? scopeKey() : null;
      if (fileField && saveState) saveState.textContent = "Saved";
    } catch (_error) {
      if (responseRegion) responseRegion.textContent = "The query request could not reach dbui. No result was received.";
      if (fileField && saveState) saveState.textContent = "Saved";
    } finally {
      setBusy(false);
      runButton.textContent = originalLabel;
      updateScope();
    }
  }

  editor.addEventListener("input", () => {
    if (writeCheckbox) writeCheckbox.checked = false;
    setDirty();
    updateScope();
  });
  editor.addEventListener("select", () => {
    if (writeCheckbox) writeCheckbox.checked = false;
    clearWriteConfirmation();
    updateScope();
  });
  editor.addEventListener("keyup", updateScope);
  editor.addEventListener("mouseup", updateScope);

  form.addEventListener("submit", (event) => {
    const submitter = event.submitter;
    const action = submitter?.formAction || form.action;
    if (action.endsWith("/query/file/create")) {
      dirty = false;
      return;
    }
    event.preventDefault();
    if (submitter?.hasAttribute("data-save-button")) void saveFile();
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
      if (saveButton) void saveFile();
      else document.querySelector("input[name=new_name][form=query-editor]")?.focus();
    }
  });

  window.addEventListener("beforeunload", (event) => {
    if (!dirty) return;
    event.preventDefault();
    event.returnValue = "";
  });

  if (!writeCheckbox) updateScope();
})();
