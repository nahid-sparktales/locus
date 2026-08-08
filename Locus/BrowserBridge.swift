import WebKit

/// The JavaScript half of the browser broker.
///
/// Split across two content worlds on purpose. Anything that has to be visible
/// to the page — patching `console` and `fetch` — must run in the page world or
/// page scripts simply would not see it, and the price is that a page can read
/// and forge that layer. Everything privileged runs in `readerWorld`, an
/// isolated world that shares the DOM but not the globals, registered so a page
/// cannot call it.
enum BrowserBridge {
    /// Isolated world for reading and driving the page.
    static let readerWorld = WKContentWorld.world(name: "locus.browser.reader")

    /// Name of the message handler the page-world capture posts to.
    static let captureHandlerName = "locusBrowserCapture"

    static func readerScript() -> WKUserScript {
        WKUserScript(
            source: readerSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: readerWorld
        )
    }

    /// Console and network capture. Runs in the **page** world because that is
    /// the only place a patched `console` or `fetch` is visible to the page's
    /// own scripts — which is also why a page can read, unpatch or forge
    /// anything this layer reports. It is report-only for exactly that reason.
    static func captureScript() -> WKUserScript {
        WKUserScript(
            source: captureSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Message the model gets when it acts on an element the page has moved on
    /// from. Mirrored verbatim in the `browser_read_page` tool description, and
    /// asserted in both test suites, so the model's instructions and the
    /// runtime cannot drift apart.
    static let staleReferenceMessage =
        "Error: page changed; call browser_read_page again."

    private static let readerSource = #"""
    (() => {
      if (globalThis.__locus) { return; }

      const byId = new Map();
      let token = 1;
      let counter = 0;

      function invalidate() {
        if (byId.size === 0) { return; }
        token += 1;
        byId.clear();
        counter = 0;
      }

      // Refs are only meaningful for the snapshot that minted them. The
      // dangerous case is not navigation — that discards everything anyway —
      // but an in-place removal, after which a fresh walk would hand the same
      // id to a different control and a click would land on the wrong thing.
      const observer = new MutationObserver((records) => {
        if (byId.size === 0) { return; }
        let removed = false;
        for (const record of records) {
          if (record.type === 'childList' && record.removedNodes.length) {
            removed = true;
            break;
          }
        }
        if (!removed) { return; }
        for (const element of byId.values()) {
          if (!element.isConnected) { invalidate(); return; }
        }
      });
      observer.observe(document.documentElement || document, {
        childList: true,
        subtree: true,
      });

      addEventListener('popstate', invalidate);
      addEventListener('pageshow', (event) => { if (event.persisted) { invalidate(); } });

      const INTERACTIVE_TAGS = new Set([
        'A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'SUMMARY', 'OPTION', 'LABEL',
      ]);
      const INTERACTIVE_ROLES = new Set([
        'button', 'link', 'checkbox', 'radio', 'textbox', 'combobox', 'listbox',
        'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'searchbox',
        'slider', 'spinbutton', 'switch', 'tab', 'treeitem',
      ]);
      const LANDMARK_TAGS = {
        MAIN: 'main', NAV: 'navigation', HEADER: 'banner', FOOTER: 'contentinfo',
        ASIDE: 'complementary', FORM: 'form', SECTION: 'region', ARTICLE: 'article',
      };
      const SECURE_AUTOCOMPLETE = new Set([
        'current-password', 'new-password', 'cc-number', 'cc-csc', 'cc-exp',
        'one-time-code',
      ]);

      function textInputRole(type) {
        switch (type) {
          case 'checkbox': return 'checkbox';
          case 'radio': return 'radio';
          case 'button': case 'submit': case 'reset': case 'image': return 'button';
          case 'range': return 'slider';
          case 'number': return 'spinbutton';
          case 'search': return 'searchbox';
          case 'hidden': return '';
          default: return 'textbox';
        }
      }

      function roleOf(element) {
        const explicit = (element.getAttribute('role') || '').trim().toLowerCase();
        if (explicit) { return explicit.split(/\s+/)[0]; }
        const tag = element.tagName;
        if (tag === 'A') { return element.hasAttribute('href') ? 'link' : ''; }
        if (tag === 'BUTTON' || tag === 'SUMMARY') { return 'button'; }
        if (tag === 'INPUT') {
          return textInputRole((element.getAttribute('type') || 'text').toLowerCase());
        }
        if (tag === 'TEXTAREA') { return 'textbox'; }
        if (tag === 'SELECT') { return element.multiple ? 'listbox' : 'combobox'; }
        if (/^H[1-6]$/.test(tag)) { return 'heading'; }
        if (tag === 'IMG') { return 'image'; }
        if (tag === 'UL' || tag === 'OL') { return 'list'; }
        if (tag === 'LI') { return 'listitem'; }
        if (tag === 'TABLE') { return 'table'; }
        if (tag === 'TR') { return 'row'; }
        if (tag === 'TD') { return 'cell'; }
        if (tag === 'TH') { return 'columnheader'; }
        if (tag === 'DIALOG') { return 'dialog'; }
        if (LANDMARK_TAGS[tag]) { return LANDMARK_TAGS[tag]; }
        return '';
      }

      function squash(value) {
        return (value || '').replace(/\s+/g, ' ').trim();
      }

      function labelledByText(element) {
        const ids = squash(element.getAttribute('aria-labelledby'));
        if (!ids) { return ''; }
        const root = element.getRootNode();
        const parts = [];
        for (const id of ids.split(' ')) {
          const target = root.getElementById ? root.getElementById(id) : null;
          if (target) { parts.push(squash(target.textContent)); }
        }
        return squash(parts.join(' '));
      }

      function associatedLabel(element) {
        if (element.labels && element.labels.length) {
          return squash(Array.from(element.labels).map((l) => l.textContent).join(' '));
        }
        const wrapper = element.closest ? element.closest('label') : null;
        return wrapper ? squash(wrapper.textContent) : '';
      }

      // Precedence follows the accessible-name algorithm closely enough that
      // controls read the way a person would describe them. Without it the
      // model sees a page full of unnamed buttons.
      function nameOf(element, role) {
        const aria = squash(element.getAttribute('aria-label'));
        if (aria) { return aria; }
        const labelled = labelledByText(element);
        if (labelled) { return labelled; }
        const tag = element.tagName;
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
          const label = associatedLabel(element);
          if (label) { return label; }
          const placeholder = squash(element.getAttribute('placeholder'));
          if (placeholder) { return placeholder; }
          const value = squash(element.getAttribute('value'));
          if (value && role === 'button') { return value; }
          const name = squash(element.getAttribute('name'));
          if (name) { return name; }
        }
        if (tag === 'IMG') {
          const alt = squash(element.getAttribute('alt'));
          if (alt) { return alt; }
        }
        const title = squash(element.getAttribute('title'));
        if (title) { return title; }
        const text = squash(element.textContent);
        return text.length > 120 ? text.slice(0, 120) + '…' : text;
      }

      function isHidden(element) {
        if (element.hasAttribute('hidden') || element.hasAttribute('inert')) { return true; }
        if (element.getAttribute('aria-hidden') === 'true') { return true; }
        const style = getComputedStyle(element);
        if (style.display === 'none' || style.visibility === 'hidden') { return true; }
        if (parseFloat(style.opacity || '1') === 0) { return true; }
        // Zero client rects catches collapsed, clipped and detached subtrees
        // without tripping over position:fixed the way offsetParent does.
        if (element.getClientRects().length === 0) { return true; }
        return false;
      }

      function isInteractive(element, role) {
        if (element.disabled) { return false; }
        if (INTERACTIVE_TAGS.has(element.tagName) && role) { return true; }
        if (INTERACTIVE_ROLES.has(role)) { return true; }
        if (element.isContentEditable) { return true; }
        const tabindex = element.getAttribute('tabindex');
        if (tabindex !== null && parseInt(tabindex, 10) >= 0) { return true; }
        return false;
      }

      function isSecure(element) {
        if (element.tagName !== 'INPUT') { return false; }
        if ((element.getAttribute('type') || '').toLowerCase() === 'password') { return true; }
        const autocomplete = (element.getAttribute('autocomplete') || '').toLowerCase();
        return SECURE_AUTOCOMPLETE.has(autocomplete.split(/\s+/).pop() || '');
      }

      function detailOf(element, role) {
        const bits = [];
        if (role === 'heading') {
          const level = element.getAttribute('aria-level')
            || (/^H([1-6])$/.exec(element.tagName) || [])[1];
          if (level) { bits.push('level=' + level); }
        }
        if (element.tagName === 'A' && element.getAttribute('href')) {
          bits.push('href=' + element.getAttribute('href').slice(0, 120));
        }
        if (element.disabled) { bits.push('disabled'); }
        if (element.checked) { bits.push('checked'); }
        if (element.getAttribute('aria-expanded')) {
          bits.push('expanded=' + element.getAttribute('aria-expanded'));
        }
        if (isSecure(element)) { bits.push('secure'); }
        return bits;
      }

      function register(element) {
        counter += 1;
        const id = 'ref_' + counter;
        byId.set(id, element);
        return id;
      }

      function childrenOf(element) {
        const kids = [];
        if (element.shadowRoot) {
          kids.push(...element.shadowRoot.children);
        }
        kids.push(...element.children);
        return kids;
      }

      function readPage(options) {
        const settings = options || {};
        const interactiveOnly = settings.filter !== 'all';
        const maxChars = Math.max(500, Math.min(settings.max_chars || 20000, 60000));
        const maxDepth = settings.depth ? Math.max(1, settings.depth) : 40;

        // Resolve the scope against the *previous* snapshot before retiring it,
        // or scoping a walk to a ref would always fail.
        const root = settings.ref_id ? resolve(settings.ref_id) : document.body;
        if (settings.ref_id && !root) {
          return { stale: true, token: token };
        }
        invalidateForFreshWalk();

        const lines = [];
        let characters = 0;
        let omitted = 0;
        let truncated = false;

        function emit(depth, text) {
          if (truncated) { omitted += 1; return; }
          if (characters + text.length > maxChars) {
            truncated = true;
            omitted += 1;
            return;
          }
          characters += text.length + depth * 2;
          lines.push('  '.repeat(depth) + text);
        }

        function walk(element, depth) {
          if (depth > maxDepth) { return; }
          if (element.tagName === 'SCRIPT' || element.tagName === 'STYLE'
              || element.tagName === 'NOSCRIPT' || element.tagName === 'TEMPLATE') {
            return;
          }
          if (isHidden(element)) { return; }

          if (element.tagName === 'IFRAME') {
            const title = squash(element.getAttribute('title')) || squash(element.getAttribute('name'));
            emit(depth, 'iframe "' + title + '" (contents not readable)');
            return;
          }

          const role = roleOf(element);
          const interactive = isInteractive(element, role);
          const structural = role === 'heading' || !!LANDMARK_TAGS[element.tagName];
          let nextDepth = depth;

          if (role && (interactive || structural || !interactiveOnly)) {
            const name = nameOf(element, role);
            let line = role;
            if (name) { line += ' "' + name + '"'; }
            if (interactive) { line += ' [' + register(element) + ']'; }
            const detail = detailOf(element, role);
            if (detail.length) { line += ' ' + detail.join(' '); }
            emit(depth, line);
            nextDepth = depth + 1;
          }

          for (const child of childrenOf(element)) {
            if (child.nodeType === 1) { walk(child, nextDepth); }
          }
        }

        if (root) { walk(root, 0); }

        return {
          token: token,
          url: location.href,
          title: document.title,
          tree: lines.join('\n'),
          truncated: truncated,
          omitted: omitted,
          count: byId.size,
        };
      }

      // A fresh walk always mints fresh ids, so the previous snapshot's ids stop
      // being answerable at that moment rather than lingering as near-misses.
      function invalidateForFreshWalk() {
        if (byId.size === 0) { return; }
        token += 1;
        byId.clear();
        counter = 0;
      }

      function resolve(id) {
        const element = byId.get(id);
        if (!element || !element.isConnected) { return null; }
        return element;
      }

      function describe(id) {
        const element = resolve(id);
        if (!element) { return { stale: true }; }
        const role = roleOf(element);
        const form = element.form || (element.closest ? element.closest('form') : null);
        const formHasSecure = !!(form && form.querySelector(
          'input[type=password], input[autocomplete~=current-password], '
          + 'input[autocomplete~=new-password], input[autocomplete~=cc-number], '
          + 'input[autocomplete~=cc-csc], input[autocomplete~=one-time-code]'
        ));
        return {
          stale: false,
          role: role,
          name: nameOf(element, role),
          secure: isSecure(element),
          formHasSecure: formHasSecure,
          tag: element.tagName,
        };
      }

      function getText(maxChars) {
        const limit = Math.max(500, Math.min(maxChars || 20000, 60000));
        const preferred = document.querySelector('main') || document.querySelector('article');
        const source = preferred || document.body;
        const text = squash(source ? source.innerText : '');
        return {
          url: location.href,
          title: document.title,
          text: text.slice(0, limit),
          truncated: text.length > limit,
        };
      }

      // ------------------------------------------------------------- acting

      function centreOf(element) {
        const rect = element.getBoundingClientRect();
        return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
      }

      function dispatchMouse(element, type, point, options) {
        const settings = options || {};
        element.dispatchEvent(new MouseEvent(type, {
          bubbles: true,
          cancelable: true,
          composed: true,
          view: window,
          clientX: point.x,
          clientY: point.y,
          button: settings.button || 0,
          buttons: type === 'mouseup' ? 0 : (settings.button === 2 ? 2 : 1),
          detail: settings.detail || 1,
          altKey: !!settings.altKey,
          ctrlKey: !!settings.ctrlKey,
          metaKey: !!settings.metaKey,
          shiftKey: !!settings.shiftKey,
        }));
      }

      function click(id, options) {
        const element = resolve(id);
        if (!element) { return { stale: true }; }
        const settings = options || {};
        element.scrollIntoView({ block: 'center', inline: 'center' });
        const point = centreOf(element);
        // Hit-testing before dispatching catches the case the model cannot see:
        // a cookie banner or modal sitting over the control it asked for.
        const top = document.elementFromPoint(point.x, point.y);
        if (top && top !== element && !element.contains(top) && !top.contains(element)) {
          return {
            blocked: true,
            by: (top.tagName || '') + (top.id ? '#' + top.id : ''),
          };
        }
        const button = settings.button === 'right' ? 2 : 0;
        dispatchMouse(element, 'pointerdown', point, { ...settings, button });
        dispatchMouse(element, 'mousedown', point, { ...settings, button });
        if (element.focus) { element.focus(); }
        dispatchMouse(element, 'mouseup', point, { ...settings, button });
        if (button === 2) {
          dispatchMouse(element, 'contextmenu', point, { ...settings, button });
        } else {
          dispatchMouse(element, 'click', point, settings);
          if (settings.detail === 2) { dispatchMouse(element, 'dblclick', point, settings); }
        }
        return { ok: true, role: roleOf(element), name: nameOf(element, roleOf(element)) };
      }

      // React and friends track input values behind the property, so a plain
      // `element.value = x` is seen, reverted, and silently does nothing. Going
      // through the prototype's setter is what makes the framework notice.
      function nativeSetValue(element, value) {
        const prototype = element instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype
          : element instanceof HTMLSelectElement
            ? HTMLSelectElement.prototype
            : HTMLInputElement.prototype;
        const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
        if (descriptor && descriptor.set) {
          descriptor.set.call(element, value);
        } else {
          element.value = value;
        }
      }

      function setValue(id, value) {
        const element = resolve(id);
        if (!element) { return { stale: true }; }
        if (element.disabled || element.readOnly) { return { blocked: true, by: 'disabled' }; }
        element.scrollIntoView({ block: 'center' });
        if (element.focus) { element.focus(); }
        if (element.type === 'checkbox' || element.type === 'radio') {
          const wanted = value === true || value === 'true' || value === 'on';
          if (element.checked !== wanted) { element.click(); }
          return { ok: true, checked: element.checked };
        }
        if (element.isContentEditable) {
          element.textContent = String(value);
        } else {
          nativeSetValue(element, String(value));
        }
        element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
        return { ok: true };
      }

      function typeText(text) {
        const element = document.activeElement;
        if (!element || element === document.body) {
          return { blocked: true, by: 'nothing is focused' };
        }
        if (element.isContentEditable) {
          element.textContent = (element.textContent || '') + text;
        } else if ('value' in element) {
          nativeSetValue(element, (element.value || '') + text);
        } else {
          return { blocked: true, by: 'the focused element takes no text' };
        }
        element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
        return { ok: true };
      }

      function pressKey(key, modifiers) {
        const element = document.activeElement || document.body;
        const flags = modifiers || {};
        for (const type of ['keydown', 'keypress', 'keyup']) {
          if (type === 'keypress' && key.length !== 1) { continue; }
          element.dispatchEvent(new KeyboardEvent(type, {
            key: key,
            bubbles: true,
            cancelable: true,
            composed: true,
            altKey: !!flags.alt,
            ctrlKey: !!flags.ctrl,
            metaKey: !!flags.meta,
            shiftKey: !!flags.shift,
          }));
        }
        if (key === 'Enter' && element.form && element.form.requestSubmit) {
          element.form.requestSubmit();
        }
        return { ok: true };
      }

      function hover(id) {
        const element = resolve(id);
        if (!element) { return { stale: true }; }
        element.scrollIntoView({ block: 'center' });
        const point = centreOf(element);
        for (const type of ['pointerover', 'mouseover', 'pointermove', 'mousemove']) {
          dispatchMouse(element, type, point, {});
        }
        return { ok: true };
      }

      function scrollBy(deltaX, deltaY) {
        window.scrollBy(deltaX || 0, deltaY || 0);
        return { ok: true, x: window.scrollX, y: window.scrollY };
      }

      function scrollTo(id) {
        const element = resolve(id);
        if (!element) { return { stale: true }; }
        element.scrollIntoView({ block: 'center', inline: 'center' });
        return { ok: true };
      }

      function drag(fromID, toID) {
        const from = resolve(fromID);
        const to = resolve(toID);
        if (!from || !to) { return { stale: true }; }
        const start = centreOf(from);
        const end = centreOf(to);
        dispatchMouse(from, 'pointerdown', start, {});
        dispatchMouse(from, 'mousedown', start, {});
        dispatchMouse(from, 'pointermove', end, {});
        dispatchMouse(to, 'mousemove', end, {});
        dispatchMouse(to, 'pointerup', end, {});
        dispatchMouse(to, 'mouseup', end, {});
        return { ok: true };
      }

      function find(query, limit) {
        const needle = String(query || '').toLowerCase().trim();
        if (!needle) { return { matches: [] }; }
        const cap = Math.max(1, Math.min(limit || 10, 50));
        const matches = [];
        for (const [id, element] of byId) {
          if (!element.isConnected) { continue; }
          const role = roleOf(element);
          const name = nameOf(element, role);
          if ((role + ' ' + name).toLowerCase().includes(needle)) {
            matches.push({ ref: id, role: role, name: name });
            if (matches.length >= cap) { break; }
          }
        }
        return { matches: matches, searched: byId.size };
      }

      // `didFinish` never fires for client-side routing, so without this every
      // interaction with a single-page app becomes a read-page polling loop.
      function waitFor(options) {
        const settings = options || {};
        const deadline = Date.now() + Math.max(100, Math.min(settings.timeout_ms || 10000, 60000));
        return new Promise((resolve_) => {
          function check() {
            if (settings.text) {
              const body = document.body ? document.body.innerText : '';
              if (body && body.toLowerCase().includes(String(settings.text).toLowerCase())) {
                return resolve_({ ok: true, reason: 'text' });
              }
            }
            if (settings.selector) {
              if (document.querySelector(settings.selector)) {
                return resolve_({ ok: true, reason: 'selector' });
              }
            }
            if (settings.ref) {
              const element = byId.get(settings.ref);
              if (element && element.isConnected) {
                return resolve_({ ok: true, reason: 'ref' });
              }
            }
            if (!settings.text && !settings.selector && !settings.ref) {
              const inFlight = globalThis.__locusInFlight || 0;
              if (inFlight === 0 && document.readyState === 'complete') {
                return resolve_({ ok: true, reason: 'idle' });
              }
            }
            if (Date.now() > deadline) {
              return resolve_({ ok: false, reason: 'timeout' });
            }
            setTimeout(check, 100);
          }
          check();
        });
      }

      globalThis.__locus = {
        readPage: readPage,
        describe: describe,
        getText: getText,
        resolve: resolve,
        currentToken: () => token,
        click: click,
        setValue: setValue,
        typeText: typeText,
        pressKey: pressKey,
        hover: hover,
        scrollBy: scrollBy,
        scrollTo: scrollTo,
        drag: drag,
        find: find,
        waitFor: waitFor,
      };
    })();
    """#

    private static let captureSource = #"""
    (() => {
      if (globalThis.__locusCapture) { return; }
      globalThis.__locusCapture = true;
      globalThis.__locusInFlight = 0;

      const post = (() => {
        const queue = [];
        let dropped = 0;
        let scheduled = false;
        // A dev build stuck in a hot-reload error loop emits thousands of
        // console lines a second, and every message hop lands on the main
        // thread. Batching with a hard cap is what keeps that from wedging the
        // interface.
        const MAX_QUEUE = 200;
        const MAX_PER_FLUSH = 100;

        function flush() {
          scheduled = false;
          if (!queue.length && !dropped) { return; }
          const batch = queue.splice(0, MAX_PER_FLUSH);
          const payload = { entries: batch, dropped: dropped };
          dropped = 0;
          try {
            webkit.messageHandlers.locusBrowserCapture.postMessage(payload);
          } catch (error) {
            // No handler on this frame; nothing to be done about it here.
          }
          if (queue.length) { schedule(); }
        }

        function schedule() {
          if (scheduled) { return; }
          scheduled = true;
          setTimeout(flush, 250);
        }

        return (entry) => {
          if (queue.length >= MAX_QUEUE) { dropped += 1; return; }
          queue.push(entry);
          schedule();
        };
      })();

      function text(value) {
        if (typeof value === 'string') { return value; }
        // An Error stringifies to "{}", which is the least useful thing the
        // model could be told about a failure. Note JavaScriptCore's `stack`
        // opens with the frame rather than the message, so the message has to
        // come first explicitly.
        if (value instanceof Error) {
          const head = String(value.name || 'Error') + ': ' + String(value.message || '');
          const frame = value.stack ? String(value.stack).split('\n')[0].trim() : '';
          return frame ? head + ' at ' + frame : head;
        }
        try { return JSON.stringify(value); } catch (error) { return String(value); }
      }

      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) {
          post({
            kind: 'console',
            level: level,
            message: args.map(text).join(' ').slice(0, 4000),
            url: location.href,
          });
          return original.apply(this, args);
        };
      }

      // Two hooks, because they see different things. A capture-phase listener
      // is the only way to see a failed <img>, <script> or <link> load — those
      // never bubble — while uncaught script exceptions are what `onerror` is
      // for, and it reports them with a message the listener does not always
      // carry.
      addEventListener('error', (event) => {
        const target = event.target;
        if (!target || target === window || !target.tagName) { return; }
        post({
          kind: 'console',
          level: 'error',
          message: 'failed to load ' + (target.src || target.href || target.tagName),
          url: location.href,
        });
      }, true);

      const previousOnError = globalThis.onerror;
      globalThis.onerror = function (message, source, line, column, error) {
        // A document with an opaque origin — anything loaded without a real
        // base URL — has its own scripts treated as cross-origin, and WebKit
        // redacts the message to "Script error." with no file or line. That is
        // the platform's behaviour, not a gap here: the page's own listeners
        // see exactly the same thing.
        post({
          kind: 'console',
          level: 'error',
          message: (error ? text(error) : String(message || 'uncaught error'))
            + (source ? ' (' + source + ':' + (line || 0) + ')' : ''),
          url: location.href,
        });
        if (typeof previousOnError === 'function') {
          return previousOnError.apply(this, arguments);
        }
        return false;
      };

      addEventListener('unhandledrejection', (event) => {
        post({
          kind: 'console',
          level: 'error',
          message: 'unhandled rejection: ' + text(event.reason).slice(0, 2000),
          url: location.href,
        });
      });

      document.addEventListener('securitypolicyviolation', (event) => {
        post({
          kind: 'console',
          level: 'error',
          message: 'CSP blocked ' + event.blockedURI + ' (' + event.violatedDirective + ')',
          url: location.href,
        });
      });

      let sequence = 0;
      const MAX_BODY = 16000;
      const TEXTUAL = /json|text|javascript|xml|html/i;

      function record(entry) {
        sequence += 1;
        post({ ...entry, kind: 'network', id: 'req_' + sequence });
      }

      const originalFetch = globalThis.fetch;
      if (typeof originalFetch === 'function') {
        globalThis.fetch = function (input, init) {
          const started = performance.now();
          const method = (init && init.method)
            || (input && input.method)
            || 'GET';
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          globalThis.__locusInFlight += 1;
          return originalFetch.apply(this, arguments).then(async (response) => {
            globalThis.__locusInFlight -= 1;
            let body = '';
            const type = response.headers.get('content-type') || '';
            if (TEXTUAL.test(type)) {
              try {
                // Cloned, so the page still gets an unread stream.
                body = (await response.clone().text()).slice(0, MAX_BODY);
              } catch (error) { body = ''; }
            }
            record({
              method: String(method).toUpperCase(),
              url: url,
              status: response.status,
              ok: response.ok,
              duration_ms: Math.round(performance.now() - started),
              content_type: type,
              body: body,
              source: 'fetch',
            });
            return response;
          }).catch((error) => {
            globalThis.__locusInFlight -= 1;
            record({
              method: String(method).toUpperCase(),
              url: url,
              status: 0,
              ok: false,
              duration_ms: Math.round(performance.now() - started),
              error: String(error),
              source: 'fetch',
            });
            throw error;
          });
        };
      }

      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__locusMethod = String(method || 'GET').toUpperCase();
        this.__locusURL = String(url || '');
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        const started = performance.now();
        globalThis.__locusInFlight += 1;
        this.addEventListener('loadend', () => {
          globalThis.__locusInFlight -= 1;
          let body = '';
          const type = this.getResponseHeader ? (this.getResponseHeader('content-type') || '') : '';
          // `responseText` throws outright when responseType is blob or
          // arraybuffer, so it is only safe to read for the text-ish cases.
          if (TEXTUAL.test(type) && (!this.responseType || this.responseType === 'text')) {
            try { body = String(this.responseText || '').slice(0, MAX_BODY); } catch (error) { body = ''; }
          }
          record({
            method: this.__locusMethod || 'GET',
            url: this.__locusURL || '',
            status: this.status,
            ok: this.status >= 200 && this.status < 400,
            duration_ms: Math.round(performance.now() - started),
            content_type: type,
            body: body,
            source: 'xhr',
          });
        });
        return send.apply(this, arguments);
      };

      // Sub-resources the browser fetches itself never touch fetch or XHR, so
      // resource timing is the only sight of them. Metadata only: no status
      // code, no headers, no body — a real limitation, not an oversight.
      try {
        if (performance.setResourceTimingBufferSize) {
          performance.setResourceTimingBufferSize(500);
        }
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            record({
              method: 'GET',
              url: entry.name,
              status: null,
              ok: true,
              duration_ms: Math.round(entry.duration),
              size: entry.transferSize || 0,
              source: 'resource',
              initiator: entry.initiatorType || '',
            });
          }
        }).observe({ type: 'resource', buffered: true });
      } catch (error) {
        // Resource timing is unavailable on this page; console and JS-initiated
        // traffic still report.
      }
    })();
    """#
}
