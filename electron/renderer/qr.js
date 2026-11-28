'use strict';
/* QR image decoding for the Servers import menu (2042).
 *
 * Self-registering on window as window.EmberQr — loaded by the
 * renderer like the other plain-script modules (script tag in
 * index.html, no bundler, no node integration in the page).
 *
 * The decoder is jsQR (pure JS, Apache-2.0/MIT dual-licensed,
 * pinned as the "jsqr" dependency in electron/package.json). Its
 * UMD bundle ships at node_modules/jsqr/dist/jsQR.js — in the
 * packaged app that file is carried by the electron-builder
 * "files" entry of the same name — and is pulled in here with a
 * dynamically inserted script tag, the same plain-script loading
 * model as controllers.js/profiles.js: in a browser context the
 * UMD assigns the global window.jsQR. Loading is lazy (first
 * decode) so app boot never pays for it, and every public entry
 * point awaits readiness, so callers never race the script tag.
 *
 * Seam:
 *   EmberQr.decodeFromImageData(imageData) -> string | null
 *     Synchronous core over an ImageData ({data,width,height}).
 *   EmberQr.decodeFromFile(file) -> Promise<string | null>
 *     File/Blob -> createImageBitmap -> canvas (downscaled so the
 *     long edge is at most 2048 px) -> getImageData -> the core.
 * Both return the decoded payload verbatim (a proxy link, or
 * several links one per line) or null when no QR code is found.
 */
(function () {
  var MAX_EDGE = 2048;
  var loadPromise = null;

  function ensureJsQR() {
    if (typeof window.jsQR === 'function') return Promise.resolve(window.jsQR);
    if (loadPromise) return loadPromise;
    loadPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      // Relative to renderer/index.html: ../node_modules/... is
      // electron/node_modules in dev and resources/app/node_modules
      // in the packaged build.
      s.src = '../node_modules/jsqr/dist/jsQR.js';
      s.onload = function () {
        if (typeof window.jsQR === 'function') resolve(window.jsQR);
        else reject(new Error('jsQR loaded but did not register a global.'));
      };
      s.onerror = function () { reject(new Error('Could not load the QR decoder (jsQR).')); };
      document.head.appendChild(s);
    });
    return loadPromise;
  }

  function decodeWith(jsQR, imageData) {
    if (!imageData || !imageData.data || !imageData.width || !imageData.height) return null;
    var code = jsQR(imageData.data, imageData.width, imageData.height, {
      inversionAttempts: 'attemptBoth',
    });
    return code && code.data ? code.data : null;
  }

  function decodeFromImageData(imageData) {
    if (typeof window.jsQR !== 'function') {
      // The core is synchronous, so the library must already be
      // loaded; kick the load off and report "not decoded" rather
      // than guessing. decodeFromFile (the menu route) awaits it.
      ensureJsQR().catch(function () {});
      return null;
    }
    return decodeWith(window.jsQR, imageData);
  }

  async function decodeFromFile(file) {
    var jsQR = await ensureJsQR();
    var bitmap = await createImageBitmap(file);
    try {
      var scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
      var w = Math.max(1, Math.round(bitmap.width * scale));
      var h = Math.max(1, Math.round(bitmap.height * scale));
      var canvas = document.createElement('canvas');
      canvas.width = w; canvas.height = h;
      var ctx = canvas.getContext('2d', { willReadFrequently: true });
      ctx.drawImage(bitmap, 0, 0, w, h);
      return decodeWith(jsQR, ctx.getImageData(0, 0, w, h));
    } finally {
      if (bitmap.close) bitmap.close();
    }
  }

  window.EmberQr = {
    decodeFromImageData: decodeFromImageData,
    decodeFromFile: decodeFromFile,
    // Exposed so tests/coordinators can await decoder readiness.
    _ready: ensureJsQR,
  };
})();
