/* =====================================================================
   סטטיסטיקת שימוש אנונימית – פיתוח חברותא
   • סופר כניסה אחת לכל ביקור בדפדפן, וצפייה אחת בכל לשונית בביקור.
   • מזהה אם הגיעו דרך הברקוד (?src=qr).
   • לא שומר IP, עוגיות, מכשיר או כל פרט מזהה. ממשק המשרתים לא נספר.
   • מוסיף לממשק המשרתים מסך "סטטיסטיקה".
   ===================================================================== */
(function () {
  "use strict";
  if (typeof CLOUD === "undefined" || !CLOUD || typeof rpc !== "function") return;

  /* ---------- ספירה ---------- */
  var KEY = "fd-visit-v1";
  var state = null;
  try { state = JSON.parse(sessionStorage.getItem(KEY) || "null"); } catch (e) {}
  var fromQr = /[?&]src=qr(&|$)/.test(location.search);
  var isAdminPage = /^#\/admin/.test(location.hash);

  function save() { try { sessionStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {} }
  function track(kind) { rpc("fd_track", { p_kind: kind, p_src: state.src }).catch(function () {}); }

  if (!state && !isAdminPage) {
    state = { src: fromQr ? "qr" : "direct", seen: {} };
    save();
    track("visit");
  }
  if (fromQr && history.replaceState) {           // מנקה את ?src=qr מהכתובת כדי שלא יועבר הלאה
    history.replaceState(null, "", location.pathname + location.hash);
  }

  function onView() {
    if (!state) return;
    var v = (location.hash.replace(/^#\/?/, "").split("/")[0]) || "new";
    if (["new", "kb", "status"].indexOf(v) < 0 || state.seen[v]) return;
    state.seen[v] = 1; save(); track(v);
  }
  window.addEventListener("hashchange", onView);
  onView();

  /* ---------- מסך סטטיסטיקה בממשק המשרתים ---------- */
  var ROLE = { member: "חבר/ה", group_servant: "משרת/ת בקבוצה", service_body: "ועדה / גוף שירות", other: "אחר", none: "לא צוין" };
  var CH = { anonymous: "🔒 אנונימי (קוד)", whatsapp: "💬 וואטסאפ", email: "✉️ מייל" };
  var VIEW = { new: "שליחת פנייה", kb: "מאגר שו\"ת", status: "בדיקת סטטוס" };
  var STATUS = { new: "חדש", in_review: "בטיפול", awaiting_clarification: "ממתין להבהרה", closed: "נענה" };

  function h(s) { return String(s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function dayAdd(iso, d) { var t = new Date(iso + "T12:00:00Z"); t.setUTCDate(t.getUTCDate() + d); return t.toISOString().slice(0, 10); }
  function sum(rows, f) { return rows.filter(f).reduce(function (a, r) { return a + r.n; }, 0); }
  function group(rows, key) { var m = {}; rows.forEach(function (r) { m[r[key]] = (m[r[key]] || 0) + r.n; }); return Object.keys(m).map(function (k) { return [k, m[k]]; }).sort(function (a, b) { return b[1] - a[1]; }); }

  function bars(pairs, labels, color) {
    var max = Math.max.apply(null, pairs.map(function (p) { return p[1]; }).concat([1]));
    if (!pairs.length) return '<p class="text-sm text-slate-400">אין עדיין נתונים</p>';
    return pairs.map(function (p) {
      return '<div class="flex items-center gap-2 text-sm py-0.5"><span class="w-32 shrink-0 truncate text-slate-700" title="' + h((labels && labels[p[0]]) || p[0]) + '">' + h((labels && labels[p[0]]) || p[0]) +
        '</span><span class="flex-1 bg-stone-100 rounded h-4 overflow-hidden"><span class="block h-4 rounded" style="width:' + Math.max(4, Math.round(p[1] / max * 100)) + '%;background:' + color + '"></span></span>' +
        '<span class="w-10 text-left font-semibold text-slate-800" dir="ltr">' + p[1] + '</span></div>';
    }).join("");
  }
  function card(title, value, sub) {
    return '<div class="bg-white rounded-xl border border-slate-200 shadow-sm p-4"><div class="text-xs text-slate-500">' + title +
      '</div><div class="text-3xl font-extrabold text-na-700 mt-1" dir="ltr" style="text-align:right">' + value + '</div>' +
      (sub ? '<div class="text-xs text-slate-400 mt-1">' + sub + '</div>' : "") + "</div>";
  }

  function render(data) {
    var today = data.today, V = data.visits || [], S = data.submissions || [];
    var visits = V.filter(function (r) { return r.kind === "visit"; });
    var since = function (d) { var from = dayAdd(today, -(d - 1)); return function (r) { return r.day >= from; }; };
    var t = sum(visits, function (r) { return r.day === today; });
    var w = sum(visits, since(7)), m = sum(visits, since(30)), all = sum(visits, function () { return true; });
    var qr30 = sum(visits, function (r) { return since(30)(r) && r.src === "qr"; });

    var days = [];
    for (var i = 13; i >= 0; i--) { var d = dayAdd(today, -i); days.push([d, sum(visits, function (r) { return r.day === d; })]); }
    var dmax = Math.max.apply(null, days.map(function (x) { return x[1]; }).concat([1]));
    var chart = '<div class="flex items-end gap-1 h-32 mt-2">' + days.map(function (x) {
      return '<div class="flex-1 flex flex-col items-center justify-end h-full" title="' + x[0] + ': ' + x[1] + '"><span class="text-[10px] text-slate-500">' + (x[1] || "") +
        '</span><span class="w-full rounded-t" style="height:' + Math.round(x[1] / dmax * 100) + '%;min-height:2px;background:#1a4f86"></span><span class="text-[10px] text-slate-400 mt-1" dir="ltr">' + x[0].slice(8) + "/" + x[0].slice(5, 7) + "</span></div>";
    }).join("") + "</div>";

    var views30 = group(V.filter(function (r) { return r.kind !== "visit" && since(30)(r); }), "kind");
    var subAll = sum(S, function () { return true; }), sub30 = sum(S, since(30));
    var open = data.open || {};

    return '' +
      '<div class="flex items-center justify-between mb-4"><h2 class="text-xl font-bold text-slate-900">📊 סטטיסטיקה</h2>' +
      '<button id="st-back" class="text-sm text-na-700 hover:underline">→ חזרה ללוח הפניות</button></div>' +
      '<div class="grid grid-cols-2 md:grid-cols-4 gap-3">' +
        card("כניסות היום", t) + card("כניסות ב-7 ימים", w) + card("כניסות ב-30 ימים", m, "מתוכן דרך הברקוד: " + qr30) + card("כניסות מאז ההפעלה", all) +
      "</div>" +
      '<div class="grid md:grid-cols-2 gap-4 mt-4">' +
        '<div class="bg-white rounded-2xl border border-slate-200 shadow-sm p-5"><div class="font-semibold text-slate-900">כניסות ב-14 הימים האחרונים</div>' + chart + "</div>" +
        '<div class="bg-white rounded-2xl border border-slate-200 shadow-sm p-5"><div class="font-semibold text-slate-900 mb-2">מה עשו באתר (30 ימים)</div>' + bars(views30, VIEW, "#2f6aa3") +
          '<div class="text-xs text-slate-400 mt-3">כל לשונית נספרת פעם אחת לכל ביקור.</div></div>' +
      "</div>" +
      '<h3 class="text-lg font-bold text-slate-900 mt-6 mb-3">פניות</h3>' +
      '<div class="grid grid-cols-2 md:grid-cols-4 gap-3">' +
        card("פניות מאז ההפעלה", subAll) + card("פניות ב-30 ימים", sub30) +
        card("ממתינות לטיפול", (open["new"] || 0) + (open.in_review || 0) + (open.awaiting_clarification || 0), "חדש: " + (open["new"] || 0) + " · בטיפול: " + ((open.in_review || 0) + (open.awaiting_clarification || 0))) +
        card("נענו", open.closed || 0, "פניות שעדיין במערכת") +
      "</div>" +
      '<div class="grid md:grid-cols-3 gap-4 mt-4">' +
        '<div class="bg-white rounded-2xl border border-slate-200 shadow-sm p-5"><div class="font-semibold text-slate-900 mb-2">מי שאל/ה</div>' + bars(group(S, "role"), ROLE, "#003366") + "</div>" +
        '<div class="bg-white rounded-2xl border border-slate-200 shadow-sm p-5"><div class="font-semibold text-slate-900 mb-2">איך ביקשו לקבל תשובה</div>' + bars(group(S, "channel"), CH, "#2f6aa3") + "</div>" +
        '<div class="bg-white rounded-2xl border border-slate-200 shadow-sm p-5"><div class="font-semibold text-slate-900 mb-2">נושאים</div>' + bars(group(S, "category").slice(0, 8), null, "#5b8dbd") + "</div>" +
      "</div>" +
      '<p class="text-xs text-slate-400 mt-4">הנתונים אנונימיים לגמרי: נספרות כמויות בלבד, בלי IP, עוגיות או פרט מזהה. כניסות של משרתים לממשק הזה לא נספרות.</p>';
  }

  function ensureButton() {
    var bar = document.getElementById("adm-refresh");
    if (!bar || document.getElementById("adm-stats-btn")) return;
    var b = document.createElement("button");
    b.id = "adm-stats-btn";
    b.className = "rounded-lg border border-na-300 bg-na-50 text-na-800 hover:bg-na-100 px-3 py-2";
    b.textContent = "📊 סטטיסטיקה";
    bar.parentNode.insertBefore(b, bar);
    var panel = document.createElement("div");
    panel.id = "adm-stats"; panel.className = "hidden";
    var board = document.getElementById("adm-board");
    board.parentNode.insertBefore(panel, board);

    function close() { panel.classList.add("hidden"); panel.innerHTML = ""; board.classList.remove("hidden"); }
    b.addEventListener("click", function () {
      if (!adminToken) return;
      document.getElementById("adm-detail").classList.add("hidden");
      board.classList.add("hidden");
      panel.classList.remove("hidden");
      panel.innerHTML = '<div class="flex items-center gap-3 text-slate-500 p-6"><span class="spinner"></span> טוען סטטיסטיקה…</div>';
      rpc("fd_admin_stats", { p_token: adminToken }).then(function (data) {
        panel.innerHTML = render(data || {});
        document.getElementById("st-back").addEventListener("click", function () { close(); if (location.hash !== "#/admin") location.hash = "#/admin"; });
      }).catch(function (e) {
        if (typeof adminAuthFail === "function" && adminAuthFail(e)) return;
        panel.innerHTML = '<div class="text-red-700 p-6">לא ניתן לטעון את הסטטיסטיקה כרגע. נסו שוב.</div>';
      });
    });
    window.addEventListener("hashchange", function () { if (!panel.classList.contains("hidden")) close(); });
    bar.addEventListener("click", function () { if (!panel.classList.contains("hidden")) close(); });
  }
  ensureButton();
})();
