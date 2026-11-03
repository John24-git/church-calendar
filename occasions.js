/* الإجازات الرسمية المصرية والأعياد والأصوام الأرثوذكسية. بتتحسب بالكود لأي سنة، من غير ما تتخزن في قاعدة البيانات.
   t: hol = إجازة رسمية، feast = عيد، fast = بداية صوم.
   التواريخ الهجرية تقريبية (التقويم الهجري المحسوب)، والإجازة الرسمية بتتأكد بإعلان مجلس الوزراء. */
(function () {
  var pad = function (n) { return String(n).padStart(2, '0'); };
  var key = function (d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); };
  var addDays = function (d, n) { return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n); };

  /* التاريخ القبطي -> ميلادي (عن طريق رقم اليوم اليولياني) */
  function copticToGreg(y, m, d) {
    var jdn = 1824664 + 365 * y + Math.floor(y / 4) + 30 * (m - 1) + d;
    return new Date(1970, 0, 1 + (jdn - 2440588));
  }
  /* عيد القيامة (حساب ميوس بالتقويم اليولياني + 13 يوم، صحيح من 1900 لـ 2099) */
  function copticEaster(y) {
    var a = y % 4, b = y % 7, c = y % 19, d = (19 * c + 15) % 30, e = (2 * a + 4 * b - d + 34) % 7;
    var month = Math.floor((d + e + 114) / 31), day = ((d + e + 114) % 31) + 1;
    return addDays(new Date(y, month - 1, day), 13);
  }

  /* أعياد وأصوام ثابتة حسب التقويم القبطي: [شهر، يوم، الاسم، النوع] */
  var FIXED = [
    [1, 1, 'عيد النيروز (رأس السنة القبطية)', 'feast'],
    [1, 17, 'عيد الصليب المجيد', 'feast'],
    [3, 16, 'بداية صوم الميلاد', 'fast'],
    [4, 28, 'برمون الميلاد', 'fast'],
    [5, 11, 'عيد الظهور الإلهي (الغطاس)', 'feast'],
    [5, 21, 'نياحة السيدة العذراء', 'feast'],
    [6, 8, 'دخول السيد المسيح الهيكل', 'feast'],
    [7, 29, 'عيد البشارة', 'feast'],
    [8, 1, 'بداية صوم الرسل (ينتهي 5 أبيب)', 'skip'],
    [9, 7, 'نياحة القديس أثناسيوس الرسولي', 'feast'],
    [9, 24, 'دخول العائلة المقدسة أرض مصر', 'feast'],
    [11, 5, 'عيد الرسل', 'feast'],
    [12, 1, 'بداية صوم السيدة العذراء', 'fast'],
    [12, 13, 'عيد التجلي', 'feast'],
    [12, 16, 'صعود جسد السيدة العذراء', 'feast']
  ];

  /* إجازات رسمية بتاريخ ميلادي ثابت */
  var HOLIDAYS = [
    [1, 7, 'عيد الميلاد المجيد'],
    [1, 25, 'عيد ثورة 25 يناير وعيد الشرطة'],
    [4, 25, 'عيد تحرير سيناء'],
    [5, 1, 'عيد العمال'],
    [6, 30, 'عيد ثورة 30 يونيو'],
    [7, 23, 'عيد ثورة 23 يوليو'],
    [10, 6, 'عيد القوات المسلحة']
  ];

  var hijriFmt = null;
  function hijriParts(d) {
    if (!hijriFmt) hijriFmt = new Intl.DateTimeFormat('en-u-ca-islamic-umalqura', { month: 'numeric', day: 'numeric' });
    var o = {};
    hijriFmt.formatToParts(d).forEach(function (p) { if (p.type === 'month' || p.type === 'day') o[p.type] = parseInt(p.value, 10); });
    return o;
  }

  var cache = {};
  function build(year) {
    var out = {};
    function add(d, name, t, approx) {
      if (d.getFullYear() !== year) return;
      var k = key(d);
      (out[k] = out[k] || []).push({ n: name, t: t, approx: !!approx });
    }
    HOLIDAYS.forEach(function (h) { add(new Date(year, h[0] - 1, h[1]), h[2], 'hol'); });

    [year - 284, year - 283].forEach(function (cy) {
      FIXED.forEach(function (f) {
        if (f[3] === 'skip') return;
        add(copticToGreg(cy, f[0], f[1]), f[2], f[3]);
      });
    });

    var easter = copticEaster(year);
    var moving = [
      [-69, 'بداية صوم يونان', 'fast'],
      [-55, 'بداية الصوم الكبير', 'fast'],
      [-7, 'أحد السعف (الشعانين)', 'feast'],
      [-3, 'خميس العهد', 'feast'],
      [-2, 'الجمعة العظيمة', 'feast'],
      [-1, 'سبت النور', 'feast'],
      [0, 'عيد القيامة المجيد', 'feast'],
      [39, 'عيد الصعود', 'feast'],
      [49, 'عيد العنصرة (حلول الروح القدس)', 'feast'],
      [50, 'بداية صوم الرسل', 'fast']
    ];
    moving.forEach(function (m) { add(addDays(easter, m[0]), m[1], m[2]); });
    add(addDays(easter, 1), 'شم النسيم', 'hol');

    /* الأعياد الإسلامية الرسمية: بنمشي على أيام السنة ونقرا التاريخ الهجري */
    for (var d = new Date(year, 0, 1); d.getFullYear() === year; d = addDays(d, 1)) {
      var h = hijriParts(d);
      if (h.month === 10 && h.day >= 1 && h.day <= 3) add(d, 'عيد الفطر المبارك' + (h.day > 1 ? ' (اليوم ' + h.day + ')' : ''), 'hol', true);
      else if (h.month === 12 && h.day === 9) add(d, 'وقفة عرفات', 'hol', true);
      else if (h.month === 12 && h.day >= 10 && h.day <= 12) add(d, 'عيد الأضحى المبارك' + (h.day > 10 ? ' (اليوم ' + (h.day - 9) + ')' : ''), 'hol', true);
      else if (h.month === 1 && h.day === 1) add(d, 'رأس السنة الهجرية', 'hol', true);
      else if (h.month === 3 && h.day === 12) add(d, 'المولد النبوي الشريف', 'hol', true);
    }
    return out;
  }

  window.occasionsOn = function (k) {
    var y = parseInt(k.slice(0, 4), 10);
    if (!cache[y]) cache[y] = build(y);
    return cache[y][k] || [];
  };
  window.occasionsDebug = { copticToGreg: copticToGreg, copticEaster: copticEaster, build: build };
})();
