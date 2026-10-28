/* زرار العين: يظهر ويخفي كلمة السر في كل خانات الباسورد */
(function () {
  var st = document.createElement('style');
  st.textContent = '.pwwrap{position:relative;display:block}.pwwrap input{padding-right:2.6rem}' +
    '.pweye{position:absolute;right:4px;top:50%;transform:translateY(-50%);border:none;background:none;padding:6px;cursor:pointer;color:#7a6a64;line-height:0}' +
    '.pweye:hover,.pweye[aria-pressed=true]{color:#6E1220}.pweye svg{width:20px;height:20px}';
  document.head.appendChild(st);
  var OPEN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7S1 12 1 12z"/><circle cx="12" cy="12" r="3"/></svg>';
  var SHUT = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.9 17.9A10.9 10.9 0 0 1 12 19C5 19 1 12 1 12a18.6 18.6 0 0 1 5.1-5.9M9.9 5.1A10.4 10.4 0 0 1 12 5c7 0 11 7 11 7a18.5 18.5 0 0 1-2.2 3.2M1 1l22 22"/></svg>';
  function wrap(inp) {
    if (inp.dataset.eye) return; inp.dataset.eye = '1';
    var w = document.createElement('span'); w.className = 'pwwrap';
    inp.parentNode.insertBefore(w, inp); w.appendChild(inp);
    var b = document.createElement('button'); b.type = 'button'; b.className = 'pweye';
    b.setAttribute('aria-label', 'إظهار كلمة السر'); b.setAttribute('aria-pressed', 'false'); b.innerHTML = OPEN;
    b.addEventListener('click', function () {
      var show = inp.type === 'password'; inp.type = show ? 'text' : 'password';
      b.setAttribute('aria-pressed', String(show)); b.innerHTML = show ? SHUT : OPEN;
      b.setAttribute('aria-label', show ? 'إخفاء كلمة السر' : 'إظهار كلمة السر');
    });
    w.appendChild(b);
  }
  function run() { document.querySelectorAll('input[type=password]').forEach(wrap); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
})();
