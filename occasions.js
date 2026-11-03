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
    [5, 10, 'برمون الغطاس', 'fast'],
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

  /* ميلادي -> قبطي (عكس copticToGreg). السنة القبطية الكبيسة هي اللي باقي قسمتها على 4 يساوي 3 */
  var MONTHS_C = ['توت', 'بابه', 'هاتور', 'كيهك', 'طوبة', 'أمشير', 'برمهات', 'برمودة', 'بشنس', 'بؤونة', 'أبيب', 'مسرى', 'النسيء'];
  var jdnOf = function (d) { return Math.round(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / 86400000) + 2440588; };
  function gregToCoptic(d) {
    var t = jdnOf(d) - 1824665, y = Math.floor(t / 366);
    while (365 * (y + 1) + Math.floor((y + 1) / 4) <= t) y++;
    var r = t - (365 * y + Math.floor(y / 4));
    return { y: y, m: Math.floor(r / 30) + 1, d: (r % 30) + 1 };
  }

  /* الفترات الكنسية. صيام الأربعاء والجمعة بيتلغي في الخماسين وفي فترة الميلاد لحد الغطاس */
  var SEASONS = { nineveh: 'صوم يونان', lent: 'الصوم الكبير', holy: 'أسبوع الآلام', fifty: 'الخماسين المقدسة',
                  nativity: 'صوم الميلاد', apostles: 'صوم الرسل', virgin: 'صوم السيدة العذراء' };
  function copticInfo(k) {
    var d = new Date(+k.slice(0, 4), +k.slice(5, 7) - 1, +k.slice(8, 10));
    var c = gregToCoptic(d), off = jdnOf(d) - jdnOf(copticEaster(d.getFullYear()));
    var season = '', fasting = false, name = '';
    if (off >= -69 && off <= -67) { season = 'nineveh'; fasting = true; }
    else if (off >= -55 && off <= -7) { season = 'lent'; fasting = true; }
    else if (off >= -6 && off <= -1) { season = 'holy'; fasting = true; }
    else if (off >= 0 && off <= 49) season = 'fifty';
    else if (off >= 50 && d <= copticToGreg(d.getFullYear() - 284, 11, 4)) { season = 'apostles'; fasting = true; }
    else if (c.m === 12 && c.d <= 15) { season = 'virgin'; fasting = true; }
    else if ((c.m === 3 && c.d >= 16) || (c.m === 4 && c.d <= 28)) { season = 'nativity'; fasting = true; }
    if (fasting) name = SEASONS[season];
    else if (c.m === 5 && c.d === 10) { name = 'برمون الغطاس'; fasting = true; }
    else {
      var dow = d.getDay(), noWeekly = season === 'fifty' || (c.m === 4 && c.d >= 29) || (c.m === 5 && c.d <= 9);
      if (!noWeekly && dow === 3) name = 'صيام الأربعاء';
      else if (!noWeekly && dow === 5) name = 'صيام الجمعة';
    }
    return { date: c.d + ' ' + MONTHS_C[c.m - 1] + ' ' + c.y, day: c.d, month: MONTHS_C[c.m - 1],
             season: season, seasonName: SEASONS[season] || '', fast: name, fasting: fasting };
  }
  window.copticInfo = copticInfo;

  window.occasionsOn = function (k) {
    var y = parseInt(k.slice(0, 4), 10);
    if (!cache[y]) cache[y] = build(y);
    return cache[y][k] || [];
  };
  window.occasionsDebug = { copticToGreg: copticToGreg, copticEaster: copticEaster, gregToCoptic: gregToCoptic, build: build };
})();
