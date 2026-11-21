/// Script run in the page before its own code. It replaces two browser features with the app's native ones:
/// - navigator.geolocation: positions come from the phone's GPS through the app (one permission, asked once,
///   in Settings > OneTurn > Location), instead of the web view's own location prompt.
/// - navigator.wakeLock: "keep the screen on" while driving.
enum Bridge {
    static let script = #"""
    (function () {
      var h = window.webkit && window.webkit.messageHandlers;
      if (!h || !h.geo) return;
      window.oneturnApp = true;

      var watchers = new Map(), once = [], nextId = 1;
      function post(op) { h.geo.postMessage({ op: op }); }
      function idle() { return watchers.size === 0 && once.length === 0; }
      function error(code, message) {
        return { code: code, message: message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 };
      }
      function call(f, v) { try { if (f) f(v); } catch (e) { setTimeout(function () { throw e; }); } }

      window.__oneturnGeo = function (kind, d) {
        var list = once.splice(0);
        list.forEach(function (w) { clearTimeout(w.timer); });
        if (kind === 'pos') {
          var p = { timestamp: d.t, coords: {
            latitude: d.lat, longitude: d.lon, accuracy: d.acc,
            altitude: d.alt == null ? null : d.alt, altitudeAccuracy: d.altAcc == null ? null : d.altAcc,
            heading: d.hdg == null ? null : d.hdg, speed: d.spd == null ? null : d.spd } };
          watchers.forEach(function (w) { call(w.ok, p); });
          list.forEach(function (w) { call(w.ok, p); });
        } else {
          var e = error(d.code, d.message);
          watchers.forEach(function (w) { call(w.err, e); });
          list.forEach(function (w) { call(w.err, e); });
        }
        if (idle()) post('stop');
      };

      var geo = {
        getCurrentPosition: function (ok, err, opt) {
          var w = { ok: ok, err: err };
          if (opt && opt.timeout > 0 && isFinite(opt.timeout)) {
            w.timer = setTimeout(function () {
              var i = once.indexOf(w);
              if (i >= 0) { once.splice(i, 1); call(err, error(3, 'Timeout')); if (idle()) post('stop'); }
            }, opt.timeout);
          }
          once.push(w); post('start');
        },
        watchPosition: function (ok, err) {
          var id = nextId++;
          watchers.set(id, { ok: ok, err: err }); post('start');
          return id;
        },
        clearWatch: function (id) {
          watchers.delete(id);
          if (idle()) post('stop');
        }
      };
      try { Object.defineProperty(Navigator.prototype, 'geolocation', { get: function () { return geo; }, configurable: true }); } catch (e) {}
      try { Object.defineProperty(navigator, 'geolocation', { value: geo, configurable: true }); } catch (e) {}

      var wake = {
        request: function () {
          h.wake.postMessage({ on: true });
          var s = { type: 'screen', released: false, onrelease: null,
            release: function () { if (!s.released) { s.released = true; h.wake.postMessage({ on: false }); } return Promise.resolve(); },
            addEventListener: function () {}, removeEventListener: function () {} };
          return Promise.resolve(s);
        }
      };
      try { Object.defineProperty(navigator, 'wakeLock', { value: wake, configurable: true }); } catch (e) {}
    })();
    """#
}
