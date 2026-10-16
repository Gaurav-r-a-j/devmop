// Grows the storage bar's segments from zero once it scrolls into view; without script it simply shows them.
class StorageBar extends HTMLElement {
  connectedCallback() {
    if (!("IntersectionObserver" in window) || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    this.toggleAttribute("data-pending", true);
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        requestAnimationFrame(() => this.removeAttribute("data-pending"));
        observer.disconnect();
      }
    }, { threshold: 0.4 });
    observer.observe(this);
  }
}

// A command with a Copy button.
class CopyCommand extends HTMLElement {
  connectedCallback() {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Copy";
    button.setAttribute("aria-label", `Copy ${this.textContent.trim()}`);
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(this.querySelector("code").textContent);
        button.textContent = "Copied";
        setTimeout(() => (button.textContent = "Copy"), 1600);
      } catch {
        button.textContent = "Select and copy";
      }
    });
    this.append(button);
  }
}

customElements.define("storage-bar", StorageBar);
customElements.define("copy-command", CopyCommand);
