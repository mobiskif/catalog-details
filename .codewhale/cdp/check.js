const puppeteer = require('puppeteer-core');
const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';

(async () => {
  const browser = await puppeteer.launch({
    executablePath: EDGE,
    headless: 'new',
    args: ['--no-sandbox', '--disable-gpu', '--window-size=1700,1000'],
    defaultViewport: { width: 1680, height: 950 },
  });
  const page = await browser.newPage();
  page.on('console', m => console.log('[console]', m.text()));
  await page.authenticate({ username: 'admin', password: '123456nN!' });

  await page.goto('http://localhost:8086/', { waitUntil: 'networkidle2', timeout: 30000 });
  // ждём, пока приложение загрузит данные
  await page.waitForFunction(() => typeof D !== 'undefined' && D && D.employees && D.employees.length > 0, { timeout: 20000 });

  // вкладка Календарь
  await page.click('nav button[data-t="cal"]');
  // отделение Админ_общий
  await page.click('#dtabs button[data-d="Админ_общий"]');
  await page.waitForFunction(() => document.querySelectorAll('#calendar tbody tr').length > 0, { timeout: 20000 });

  // сбрасываем фильтр подразделения, чтобы Пархимович точно был в списке
  await page.select('#cs', '');
  await new Promise(r => setTimeout(r, 500));

  // на всякий случай снимок DOM-представления
  const result = await page.evaluate(() => {
    const rows = [...document.querySelectorAll('#calendar tbody tr')];
    const out = {};
    function dump(label) {
      const row = rows.find(tr => {
        const n = tr.querySelector('td.name');
        return n && n.textContent.includes(label);
      });
      if (!row) { out[label] = 'НЕ НАЙДЕН'; return; }
      const cells = [...row.querySelectorAll('td.day')];
      out[label] = cells.map(td => {
        const bg = getComputedStyle(td).backgroundColor;
        return { d: td.dataset.d, cls: td.className, bg };
      }).filter(x => /O|D|B|U/.test(x.cls)).map(x => {
        // индекс дня -> дата (Y=2027, день 0 = 1 января)
        const base = new Date(2027, 0, 1);
        base.setDate(base.getDate() + Number(x.d));
        const iso = base.getFullYear() + '-' + String(base.getMonth() + 1).padStart(2, '0') + '-' + String(base.getDate()).padStart(2, '0');
        return iso + '  class="' + x.cls + '"  bg=' + x.bg;
      });
    }
    dump('Пархимович');
    dump('Морозов');
    return out;
  });

  console.log('=== ЯЧЕЙКИ С ЦВЕТОМ (Пархимович / Морозов) ===');
  console.log(JSON.stringify(result, null, 2));

  await page.screenshot({ path: 'C:\\VacationDashboard\\data\\calendar.png', fullPage: false });

  // Крупный скриншот только таблицы календаря
  const wrap = await page.$('.calwrap');
  if (wrap) await wrap.screenshot({ path: 'C:\\VacationDashboard\\data\\calendar_table.png' });

  await browser.close();
  console.log('DONE');
})().catch(e => { console.error('ERR', e); process.exit(1); });
