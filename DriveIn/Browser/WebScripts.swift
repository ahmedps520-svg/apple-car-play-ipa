import Foundation

/// JavaScript injected into pages. Raw strings so regex backslashes stay intact.
enum WebScripts {
    static let mediaHandlerName = "driveInMedia"

    /// Injected at document start in every frame when "Car-compatible video" is on.
    ///
    /// Before iOS 17.1 iPhone Safari had no Media Source Extensions, so video sites still
    /// ship a fallback that sets `<video src>` to a plain HLS (.m3u8) or MP4 URL. Hiding
    /// MSE makes them use it, and a plain URL is something AVPlayer, AirPlay and the
    /// CarPlay video player can play. DRM content (Netflix etc.) is unaffected: it simply
    /// won't play outside the site's own player.
    static let hideMediaSourceExtensions = #"""
    (function () {
      if (window.__driveInMSEHidden) { return; }
      window.__driveInMSEHidden = true;
      ['MediaSource', 'ManagedMediaSource', 'WebKitMediaSource', 'SourceBuffer', 'ManagedSourceBuffer'].forEach(function (name) {
        try { delete window[name]; } catch (e) {}
        try {
          if (name in window) {
            Object.defineProperty(window, name, { value: undefined, configurable: true, writable: true });
          }
        } catch (e) {}
      });
    })();
    """#

    /// Injected at document end in every frame. Reports `<video>`/`<audio>` sources to the app.
    static let mediaObserver = #"""
    (function () {
      if (window.__driveInMediaObserver) { return; }
      window.__driveInMediaObserver = true;
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.driveInMedia;
      if (!bridge) { return; }
      var timer = null;
      var lastPayload = '';

      function absolute(url) {
        if (!url) { return null; }
        try { return new URL(url, document.baseURI).href; } catch (e) { return null; }
      }
      function meta(name) {
        var el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
        return el ? el.getAttribute('content') : null;
      }
      function sourceOf(el) {
        var src = el.currentSrc || el.src || '';
        if (!src) {
          var source = el.querySelector('source[src]');
          if (source) { src = absolute(source.getAttribute('src')) || ''; }
        }
        return src || null;
      }
      function collect() {
        timer = null;
        var items = [];
        var elements = document.querySelectorAll('video, audio');
        for (var i = 0; i < elements.length && items.length < 20; i++) {
          var el = elements[i];
          var src = sourceOf(el);
          if (!src) { continue; }
          var d = el.duration;
          items.push({
            tag: el.tagName.toLowerCase(),
            src: src,
            poster: el.poster ? absolute(el.poster) : null,
            duration: isFinite(d) ? d : (d === Infinity ? -1 : null),
            width: el.videoWidth || 0,
            height: el.videoHeight || 0,
            title: el.getAttribute('title') || el.getAttribute('aria-label') || null
          });
        }
        var ogVideo = meta('og:video:secure_url') || meta('og:video:url') || meta('og:video');
        var payload = {
          type: 'media',
          frameURL: location.href,
          isTop: window.top === window,
          pageTitle: document.title || '',
          ogTitle: meta('og:title'),
          ogImage: absolute(meta('og:image')),
          ogVideo: absolute(ogVideo),
          media: items
        };
        var serialized = JSON.stringify(payload);
        if (serialized === lastPayload) { return; }
        lastPayload = serialized;
        try { bridge.postMessage(payload); } catch (e) {}
      }
      function schedule() {
        if (timer) { return; }
        timer = setTimeout(collect, 500);
      }
      ['loadstart', 'loadedmetadata', 'durationchange', 'play', 'emptied'].forEach(function (type) {
        document.addEventListener(type, schedule, true);
      });
      function containsMedia(node) {
        if (!node || node.nodeType !== 1) { return false; }
        var tag = node.tagName;
        if (tag === 'VIDEO' || tag === 'AUDIO' || tag === 'SOURCE') { return true; }
        return !!(node.querySelector && node.querySelector('video, audio'));
      }
      try {
        new MutationObserver(function (mutations) {
          for (var i = 0; i < mutations.length; i++) {
            var added = mutations[i].addedNodes;
            for (var j = 0; j < added.length; j++) {
              if (containsMedia(added[j])) { schedule(); return; }
            }
          }
        }).observe(document.documentElement || document, { childList: true, subtree: true });
      } catch (e) {}
      window.addEventListener('pageshow', schedule);
      window.__driveInRescan = function () { lastPayload = ''; schedule(); };
      schedule();
    })();
    """#

    static let rescanMedia = "window.__driveInRescan && window.__driveInRescan();"

    /// Evaluated on demand in the top frame. Returns JSON `{title, links: [{title, url, thumb}]}`.
    static let linkExtractor = #"""
    (function () {
      function absolute(url) {
        if (!url) { return null; }
        try { return new URL(url, document.baseURI).href; } catch (e) { return null; }
      }
      function clean(text) { return (text || '').replace(/\s+/g, ' ').trim(); }
      var byKey = {};
      var order = [];
      var here = location.href.split('#')[0];
      var anchors = document.querySelectorAll('a[href]');
      for (var i = 0; i < anchors.length && order.length < 150; i++) {
        var a = anchors[i];
        var href = absolute(a.getAttribute('href'));
        if (!href || !/^https?:/i.test(href)) { continue; }
        var key = href.split('#')[0];
        if (key === here) { continue; }
        var rect = a.getBoundingClientRect();
        if (rect.width < 1 || rect.height < 1) { continue; }
        var img = a.querySelector('img');
        var thumb = null;
        if (img) {
          thumb = img.currentSrc || img.src || img.getAttribute('data-src') || img.getAttribute('data-thumb') || null;
          if (thumb && thumb.indexOf('data:') === 0) { thumb = img.getAttribute('data-src') || img.getAttribute('data-thumb') || null; }
        }
        // Prefer real link text; fall back to the image's alt text.
        var text = clean(a.getAttribute('aria-label') || a.getAttribute('title') || a.innerText);
        var quality = text.length >= 2 ? 2 : 0;
        if (!quality && img) {
          text = clean(img.getAttribute('alt'));
          quality = text.length >= 2 ? 1 : 0;
        }
        var existing = byKey[key];
        if (existing) {
          // Thumbnail and title are often separate links to the same page: merge them.
          if (quality > existing.quality) { existing.title = text.slice(0, 140); existing.quality = quality; }
          if (!existing.thumb && thumb) { existing.thumb = absolute(thumb); }
          continue;
        }
        if (!quality && !thumb) { continue; }
        byKey[key] = { title: text.slice(0, 140), url: href, thumb: absolute(thumb), quality: quality };
        order.push(key);
      }
      var results = [];
      for (var j = 0; j < order.length; j++) {
        var entry = byKey[order[j]];
        if (entry.quality > 0) { results.push({ title: entry.title, url: entry.url, thumb: entry.thumb }); }
      }
      return JSON.stringify({ title: document.title || '', links: results });
    })();
    """#

    /// Injected at document end into the top frame of the CarPlay-window web view only.
    /// CarPlay delivers no taps to the window, so the app drives the page from here.
    static let carInteraction = #"""
    (function () {
      if (window.__driveInCar) { return; }

      function clientPoint(fx, fy) {
        var vv = window.visualViewport;
        if (vv) { return { x: vv.offsetLeft + fx * vv.width, y: vv.offsetTop + fy * vv.height }; }
        return { x: fx * window.innerWidth, y: fy * window.innerHeight };
      }
      function deepElementAt(x, y) {
        var el = document.elementFromPoint(x, y);
        var depth = 0;
        while (el && (el.tagName === 'IFRAME' || el.tagName === 'FRAME') && depth < 5) {
          try {
            var inner = el.contentDocument;
            if (!inner) { break; }
            var r = el.getBoundingClientRect();
            x -= r.left;
            y -= r.top;
            var next = inner.elementFromPoint(x, y);
            if (!next) { break; }
            el = next;
            depth++;
          } catch (e) { break; }
        }
        return { el: el, x: x, y: y };
      }
      function fire(el, type, x, y, isPointer) {
        try {
          var init = {
            bubbles: true, cancelable: true, composed: true, view: window,
            clientX: x, clientY: y, button: 0, buttons: type.indexOf('down') >= 0 ? 1 : 0
          };
          if (isPointer) {
            init.pointerId = 1;
            init.pointerType = 'mouse';
            init.isPrimary = true;
            el.dispatchEvent(new PointerEvent(type, init));
          } else {
            el.dispatchEvent(new MouseEvent(type, init));
          }
        } catch (e) {}
      }
      function isEditable(el) {
        if (!el) { return false; }
        if (el.isContentEditable || el.tagName === 'TEXTAREA') { return true; }
        if (el.tagName === 'INPUT') {
          var type = (el.getAttribute('type') || 'text').toLowerCase();
          return ['text', 'search', 'email', 'url', 'tel', 'password', 'number'].indexOf(type) >= 0;
        }
        return false;
      }
      function pickVideo() {
        var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
        for (var i = 0; i < videos.length; i++) { if (!videos[i].paused) { return videos[i]; } }
        var best = null;
        var bestArea = 0;
        videos.forEach(function (v) {
          var r = v.getBoundingClientRect();
          var area = r.width * r.height;
          if (area > bestArea) { bestArea = area; best = v; }
        });
        return best;
      }
      function keepInline(v) {
        try {
          v.setAttribute('playsinline', '');
          v.setAttribute('webkit-playsinline', '');
          v.playsInline = true;
        } catch (e) {}
      }

      var api = {
        clickAt: function (fx, fy) {
          var p = clientPoint(fx, fy);
          var hit = deepElementAt(p.x, p.y);
          var el = hit.el;
          if (!el) { return JSON.stringify({ hit: false }); }
          var hasPointer = typeof window.PointerEvent === 'function';
          if (hasPointer) { fire(el, 'pointerdown', hit.x, hit.y, true); }
          fire(el, 'mousedown', hit.x, hit.y, false);
          if (hasPointer) { fire(el, 'pointerup', hit.x, hit.y, true); }
          fire(el, 'mouseup', hit.x, hit.y, false);
          var editable = isEditable(el);
          if (typeof el.focus === 'function') {
            try { el.focus({ preventScroll: true }); } catch (e) {}
          }
          if (typeof el.click === 'function') { el.click(); } else { fire(el, 'click', hit.x, hit.y, false); }
          var link = el.closest ? el.closest('a[href]') : null;
          return JSON.stringify({
            hit: true,
            tag: el.tagName,
            editable: editable,
            value: editable ? (el.value || el.textContent || '') : null,
            href: link ? link.href : null
          });
        },

        typeText: function (text, submit) {
          var el = document.activeElement;
          while (el && (el.tagName === 'IFRAME' || el.tagName === 'FRAME')) {
            try { el = el.contentDocument.activeElement; } catch (e) { break; }
          }
          if (!isEditable(el)) { return false; }
          if (el.isContentEditable) {
            el.textContent = text;
          } else {
            var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            var descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
            if (descriptor && descriptor.set) { descriptor.set.call(el, text); } else { el.value = text; }
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          if (submit) {
            var init = { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true };
            var press = function (type) {
              var ev = new KeyboardEvent(type, init);
              try {
                Object.defineProperty(ev, 'keyCode', { get: function () { return 13; } });
                Object.defineProperty(ev, 'which', { get: function () { return 13; } });
              } catch (e) {}
              return el.dispatchEvent(ev);
            };
            var proceed = press('keydown');
            press('keypress');
            press('keyup');
            if (proceed && el.form) {
              if (typeof el.form.requestSubmit === 'function') { el.form.requestSubmit(); } else { el.form.submit(); }
            }
          }
          return true;
        },

        scrollAt: function (fx, fy, dx, dy) {
          var p = clientPoint(fx, fy);
          var el = document.elementFromPoint(p.x, p.y);
          while (el && el !== document.body && el !== document.documentElement) {
            var style = getComputedStyle(el);
            var canY = /(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight + 1;
            var canX = /(auto|scroll)/.test(style.overflowX) && el.scrollWidth > el.clientWidth + 1;
            if ((dy && canY) || (dx && canX)) { el.scrollBy(dx, dy); return true; }
            el = el.parentElement;
          }
          window.scrollBy(dx, dy);
          return false;
        },

        togglePlay: function () {
          var v = pickVideo();
          if (!v) { return 'none'; }
          if (v.paused) {
            var promise = v.play();
            if (promise && promise.catch) { promise.catch(function () {}); }
            return 'playing';
          }
          v.pause();
          return 'paused';
        },

        theater: function (on) {
          var styleId = '__driveInTheaterStyle';
          var current = document.querySelector('video.__driveInTheater');
          if (current) { current.classList.remove('__driveInTheater'); }
          var style = document.getElementById(styleId);
          if (!on) {
            if (style) { style.remove(); }
            return 'off';
          }
          var v = pickVideo();
          if (!v) { return 'none'; }
          if (!style) {
            style = document.createElement('style');
            style.id = styleId;
            style.textContent = 'video.__driveInTheater{position:fixed!important;left:0!important;top:0!important;' +
              'width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;' +
              'z-index:2147483647!important;background:#000!important;object-fit:contain!important;transform:none!important;}';
            (document.head || document.documentElement).appendChild(style);
          }
          v.classList.add('__driveInTheater');
          return 'on';
        }
      };

      // Keep video inside the page: native fullscreen would open on the iPhone, not the car.
      document.querySelectorAll('video').forEach(keepInline);
      document.addEventListener('play', function (e) {
        if (e.target && e.target.tagName === 'VIDEO') { keepInline(e.target); }
      }, true);
      try {
        HTMLVideoElement.prototype.webkitEnterFullscreen = function () {};
        HTMLVideoElement.prototype.webkitEnterFullScreen = function () {};
      } catch (e) {}

      window.__driveInCar = api;
    })();
    """#

    /// Builds a call like `window.__driveInCar.clickAt(0.5, 0.25)` with JSON-encoded arguments.
    static func carCall(_ function: String, _ arguments: [Any]) -> String {
        let encoded = arguments.map { argument -> String in
            if let string = argument as? String {
                return jsonString(string)
            }
            if let bool = argument as? Bool {
                return bool ? "true" : "false"
            }
            if let number = argument as? Double {
                return number.isFinite ? String(number) : "0"
            }
            if let number = argument as? CGFloat {
                return Double(number).isFinite ? String(Double(number)) : "0"
            }
            if let number = argument as? Int {
                return String(number)
            }
            return "null"
        }
        return "window.__driveInCar ? window.__driveInCar.\(function)(\(encoded.joined(separator: ", "))) : null"
    }

    static func jsonString(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string], options: []),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        // Strip the surrounding [ ] of the one-element array.
        return String(array.dropFirst().dropLast())
    }
}
