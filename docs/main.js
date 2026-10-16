const motionOK = matchMedia("(prefers-reduced-motion: no-preference)").matches && "IntersectionObserver" in window;

// Calls `play` once when `element` is mostly in view.
function whenVisible(element, play, threshold = 0.35) {
  const observer = new IntersectionObserver((entries) => {
    if (entries.some((entry) => entry.isIntersecting)) {
      observer.disconnect();
      play();
    }
  }, { threshold });
  observer.observe(element);
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Arms an element (hidden start state) and plays it on view; without motion it stays in its finished state.
function playOnView(element, play) {
  if (!motionOK) return;
  element.toggleAttribute("data-armed", true);
  whenVisible(element, () => requestAnimationFrame(() => {
    element.toggleAttribute("data-play", true);
    play?.();
  }));
}

// The hero window runs a short "scan", then reveals its results.
class ScanWindow extends HTMLElement {
  connectedCallback() {
    if (!motionOK) return;
    const status = this.querySelector(".status");
    const done = status.textContent;
    this.toggleAttribute("data-armed", true);
    whenVisible(this, async () => {
      await wait(900);
      status.textContent = status.dataset.busy;
      this.toggleAttribute("data-scanning", true);
      await wait(1300);
      status.textContent = done;
      this.toggleAttribute("data-play", true);
      this.querySelectorAll("count-up").forEach((counter) => counter.run());
    }, 0.01);
  }
}

// Counts a number up from zero when asked.
class CountUp extends HTMLElement {
  run() {
    const target = Number(this.dataset.to);
    const start = performance.now();
    const duration = 1200;
    const tick = (now) => {
      const progress = Math.min(1, (now - start) / duration);
      this.textContent = Math.round(target * (1 - Math.pow(1 - progress, 3)));
      if (progress < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }
}

// The storage bar is animated by its parent window; on its own it simply shows.
class StorageBar extends HTMLElement {}

// Pins a screen beside the steps and switches it as each step scrolls into the middle of the view.
class StorySteps extends HTMLElement {
  connectedCallback() {
    if (!("IntersectionObserver" in window)) return;
    const steps = [...this.querySelectorAll("[data-step]")];
    const activate = (step) => {
      this.dataset.active = step.dataset.step;
      steps.forEach((item) => item.toggleAttribute("data-current", item === step));
    };
    activate(steps[0]);
    const observer = new IntersectionObserver((entries) => {
      const visible = entries.filter((entry) => entry.isIntersecting);
      if (visible.length) activate(visible[visible.length - 1].target);
    }, { rootMargin: "-45% 0px -45% 0px" });
    steps.forEach((step) => observer.observe(step));
  }
}

// Plays the "stop a leftover server" demo in a loop while it's on screen.
class ProcessDemo extends HTMLElement {
  connectedCallback() {
    if (!motionOK) return;
    this.visible = false;
    new IntersectionObserver((entries) => {
      this.visible = entries.some((entry) => entry.isIntersecting);
      if (this.visible && !this.running) this.loop();
    }, { threshold: 0.4 }).observe(this);
  }

  async loop() {
    this.running = true;
    const victim = this.querySelector(".victim");
    const stop = victim.querySelector(".stop");
    const toast = this.querySelector(".toast");
    while (this.visible) {
      await wait(1600);
      stop.classList.add("pressed");
      await wait(450);
      stop.classList.remove("pressed");
      victim.classList.add("gone");
      toast.classList.add("show");
      await wait(2400);
      toast.classList.remove("show");
      await wait(500);
      victim.classList.remove("gone");
    }
    this.running = false;
  }
}

// Types each command, then shows its output, once the terminal is visible.
class TypeTerminal extends HTMLElement {
  connectedCallback() {
    if (!motionOK) return;
    this.toggleAttribute("data-armed", true);
    const commands = [...this.querySelectorAll(".cmd")];
    commands.forEach((command) => (command.querySelector(".typed").textContent = ""));
    whenVisible(this, async () => {
      for (const command of commands) {
        const typed = command.querySelector(".typed");
        typed.classList.add("caret");
        await wait(500);
        for (const character of command.dataset.type) {
          typed.textContent += character;
          await wait(70 + Math.random() * 60);
        }
        await wait(350);
        typed.classList.remove("caret");
        let next = command.nextElementSibling;
        while (next && next.classList.contains("out")) {
          next.classList.add("shown");
          await wait(180);
          next = next.nextElementSibling;
        }
        await wait(600);
      }
    }, 0.5);
  }
}

// Ticks through the last checks before a delete, then shows the result.
class SafetyCheck extends HTMLElement {
  connectedCallback() {
    if (!motionOK) return;
    this.toggleAttribute("data-armed", true);
    whenVisible(this, async () => {
      for (const item of this.querySelectorAll("li")) {
        await wait(420);
        item.classList.add("passed");
      }
      await wait(500);
      this.querySelector(".check-done").classList.add("shown");
    }, 0.3);
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

customElements.define("scan-window", ScanWindow);
customElements.define("count-up", CountUp);
customElements.define("storage-bar", StorageBar);
customElements.define("story-steps", StorySteps);
customElements.define("process-demo", ProcessDemo);
customElements.define("type-terminal", TypeTerminal);
customElements.define("copy-command", CopyCommand);
customElements.define("safety-check", SafetyCheck);

document.querySelectorAll(".cascade, .rows.compare, .rows.map").forEach((element) => playOnView(element));

// Highlights the nav link for the section in view, mirrored to aria-current for assistive tech.
const navLinks = [...document.querySelectorAll("[data-spy] a[href^='#']")].filter((link) => link.getAttribute("href").length > 1);
const sections = navLinks.map((link) => document.querySelector(link.getAttribute("href"))).filter(Boolean);
if ("IntersectionObserver" in window && sections.length) {
  const spy = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      navLinks.forEach((link) => link.setAttribute("aria-current", String(link.getAttribute("href") === `#${entry.target.id}`)));
    }
  }, { rootMargin: "-45% 0px -50% 0px" });
  sections.forEach((section) => spy.observe(section));
}
