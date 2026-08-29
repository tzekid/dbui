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

  const form = document.querySelector("form[data-query-form]");
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
  const encoder = new TextEncoder();
  let dirty = (!fileField && editor.value.length > 0) || Boolean(saveState?.hasAttribute("data-initial-dirty"));
  let busy = false;
  let pendingConfirmation = null;

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
