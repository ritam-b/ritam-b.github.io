/*
 * pub-abstracts.js — hover-to-expand abstracts for the publications list.
 *
 * Standalone, dependency-free, and style-agnostic. Loaded site-wide from the
 * default layout; it no-ops on any page that has no publication entries.
 *
 * How it finds entries and their abstract text:
 *   Each publication renders (via _includes/content/pub.html) as a <p> that,
 *   when an abstract is known, carries a `data-abstract` attribute holding the
 *   abstract text. This script attaches to exactly those elements. Entries
 *   without a `data-abstract` are left completely alone (no listeners, no
 *   visual change), so the feature lights up paper-by-paper as abstracts are
 *   filled into _data/abstracts.yml.
 *
 * Interaction:
 *   - Mouse: pause on an entry for HOVER_DELAY ms -> its abstract panel
 *     expands in place with a smooth height/opacity transition. Moving the
 *     pointer away (or onto another entry, or clicking elsewhere, or pressing
 *     Escape) collapses it. Leaving before the delay elapses cancels — nothing
 *     flickers open.
 *   - Keyboard/AX: entries are focusable; focusing one expands its abstract
 *     immediately (no delay — keyboard users shouldn't have to wait), blurring
 *     collapses it. Respects prefers-reduced-motion by skipping the animation.
 *
 * The panel's styles are injected by this script (see STYLE below) so the
 * feature stays fully self-contained and doesn't depend on any theme CSS.
 *
 * LaTeX in the abstracts ($...$ inline, $$...$$ or \[...\] display) is rendered
 * with MathJax, lazy-loaded from a CDN the first time any abstract is expanded
 * (see ensureMathJax). Visitors who never open an abstract never load it, and
 * if it can't load the abstract simply shows its raw TeX — no breakage.
 */
(function () {
	"use strict";

	var HOVER_DELAY = 2000; // ms to pause before a hover expands an entry
	var COLLAPSE_GRACE = 120; // ms tolerance for pointer jitter / crossing gaps

	// Only run where there's something to do.
	function collectEntries() {
		return Array.prototype.slice.call(
			document.querySelectorAll("[data-abstract]")
		).filter(function (el) {
			return (el.getAttribute("data-abstract") || "").trim().length > 0;
		});
	}

	var prefersReducedMotion =
		window.matchMedia &&
		window.matchMedia("(prefers-reduced-motion: reduce)").matches;

	// --- injected, self-contained styles -----------------------------------
	// Colours inherit from the surrounding text (currentColor / inherit) so the
	// panel looks right in either style and in the treatise day/night modes.
	var STYLE = [
		".pub-abstract {",
		"  display: block;",
		"  overflow: hidden;",
		"  max-height: 0;",
		"  opacity: 0;",
		"  margin: 0;",
		"  border-left: 2px solid currentColor;",
		"  padding-left: 0;",
		"  font-size: 0.92em;",
		"  line-height: 1.5;",
		"  white-space: pre-wrap;", // ePrint abstracts keep their paragraph breaks
		"  color: inherit;",
		"  transition: max-height 0.45s ease, opacity 0.35s ease,",
		"    margin-top 0.45s ease, padding-left 0.45s ease;",
		"}",
		".pub-abstract-open {",
		"  max-height: 60em;", // generous cap; abstracts are short enough
		"  opacity: 0.85;",
		"  margin-top: 0.5em;",
		"  padding-left: 0.75em;",
		"}",
		"[data-abstract] { cursor: help; }",
		"@media (prefers-reduced-motion: reduce) {",
		"  .pub-abstract { transition: none; }",
		"}"
	].join("\n");

	function injectStyle() {
		if (document.getElementById("pub-abstracts-style")) return;
		var s = document.createElement("style");
		s.id = "pub-abstracts-style";
		s.textContent = STYLE;
		(document.head || document.documentElement).appendChild(s);
	}

	// --- LaTeX rendering (MathJax, lazy-loaded on first expand) -------------
	var MATHJAX_SRC = "https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js";
	var mjState = "none"; // none | loading | ready
	var mjQueue = [];

	// Load MathJax once, on demand, then run cb. ePrint abstracts use $...$ for
	// inline math, so that delimiter is enabled (off by default in MathJax).
	function ensureMathJax(cb) {
		if (mjState === "ready") { cb(); return; }
		mjQueue.push(cb);
		if (mjState === "loading") return;
		mjState = "loading";
		window.MathJax = {
			tex: {
				inlineMath: [["$", "$"], ["\\(", "\\)"]],
				displayMath: [["$$", "$$"], ["\\[", "\\]"]]
			},
			// Render math at the surrounding text's actual font-size. MathJax's
			// default (matchFontHeight) rescales to match x-heights, which badly
			// undersizes math against this site's serif fonts (~56%).
			chtml: { matchFontHeight: false },
			options: { enableMenu: false },
			startup: {
				typeset: false, // typeset panels on demand, not the whole page
				ready: function () {
					window.MathJax.startup.defaultReady();
					window.MathJax.startup.promise.then(function () {
						mjState = "ready";
						var q = mjQueue; mjQueue = [];
						q.forEach(function (f) { f(); });
					});
				}
			}
		};
		var s = document.createElement("script");
		s.src = MATHJAX_SRC;
		s.async = true;
		s.onerror = function () { mjState = "none"; mjQueue = []; }; // keep raw TeX
		(document.head || document.documentElement).appendChild(s);
	}

	// Typeset a panel's math exactly once.
	function renderMath(panel) {
		if (panel._mathDone) return;
		panel._mathDone = true;
		ensureMathJax(function () {
			if (window.MathJax && window.MathJax.typesetPromise) {
				window.MathJax.typesetPromise([panel]).catch(function () {});
			}
		});
	}

	// --- per-entry setup ----------------------------------------------------
	function setupEntry(entry) {
		var text = (entry.getAttribute("data-abstract") || "").trim();
		if (!text) return;

		// Build the collapsible panel once, appended inside the entry <p>.
		var panel = document.createElement("span");
		panel.className = "pub-abstract";
		panel.setAttribute("role", "note");
		panel.textContent = text;
		entry.appendChild(panel);

		// Make the entry keyboard-reachable and announce the behaviour.
		if (!entry.hasAttribute("tabindex")) entry.setAttribute("tabindex", "0");
		entry.setAttribute("aria-label",
			(entry.textContent || "").replace(text, "").trim());

		var openTimer = null;
		var closeTimer = null;

		function clearTimers() {
			if (openTimer) { clearTimeout(openTimer); openTimer = null; }
			if (closeTimer) { clearTimeout(closeTimer); closeTimer = null; }
		}

		function open() {
			clearTimers();
			if (panel.classList.contains("pub-abstract-open")) return;
			// Collapse any sibling that's currently open, so only one shows.
			closeOthers(entry);
			panel.classList.add("pub-abstract-open");
			entry.setAttribute("aria-expanded", "true");
			renderMath(panel); // render LaTeX the first time this panel opens
		}

		function close() {
			clearTimers();
			panel.classList.remove("pub-abstract-open");
			entry.setAttribute("aria-expanded", "false");
		}

		entry._pubAbstractClose = close;

		// Mouse: delayed open, grace-period close.
		entry.addEventListener("mouseenter", function () {
			if (closeTimer) { clearTimeout(closeTimer); closeTimer = null; }
			if (panel.classList.contains("pub-abstract-open")) return;
			openTimer = setTimeout(open, HOVER_DELAY);
		});
		entry.addEventListener("mouseleave", function () {
			if (openTimer) { clearTimeout(openTimer); openTimer = null; }
			closeTimer = setTimeout(close, COLLAPSE_GRACE);
		});

		// Keyboard/AX: focus expands immediately, blur collapses.
		entry.addEventListener("focus", open);
		entry.addEventListener("blur", close);

		entry.setAttribute("aria-expanded", "false");
	}

	var entries = [];

	function closeOthers(except) {
		for (var i = 0; i < entries.length; i++) {
			if (entries[i] !== except && entries[i]._pubAbstractClose) {
				entries[i]._pubAbstractClose();
			}
		}
	}

	function init() {
		entries = collectEntries();
		if (!entries.length) return; // nothing to do on this page
		injectStyle();
		entries.forEach(setupEntry);

		// Click anywhere outside an expanded entry collapses it.
		document.addEventListener("click", function (e) {
			var host = e.target.closest ? e.target.closest("[data-abstract]") : null;
			closeOthers(host);
		});
		// Escape collapses everything.
		document.addEventListener("keydown", function (e) {
			if (e.key === "Escape" || e.key === "Esc") closeOthers(null);
		});
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", init);
	} else {
		init();
	}
})();
