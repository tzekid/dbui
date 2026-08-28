(() => {
  "use strict";

  document.addEventListener("keydown", (event) => {
    if (!(event.ctrlKey || event.metaKey) || event.key !== "Enter") return;
    const form = event.target.closest?.("form[data-query-form]");
    if (!form) return;
    event.preventDefault();
    form.requestSubmit();
  });

  const search = document.querySelector("[data-object-search]");
  if (search) {
    search.addEventListener("input", () => {
      const query = search.value.toLocaleLowerCase();
      document.querySelectorAll("[data-object-name]").forEach((item) => {
        item.hidden = !item.dataset.objectName.toLocaleLowerCase().includes(query);
      });
    });
  }
})();
