const puppeteer = require('puppeteer-core');
const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const browser = await puppeteer.launch({
    executablePath: EDGE, headless: 'new',
    args: ['--no-sandbox', '--disable-gpu'],
    defaultViewport: { width: 1680, height: 900 },
  });
  const page = await browser.newPage();
  await page.authenticate({ username: 'admin', password: '123456nN!' });
  await page.goto('http://localhost:8086/', { waitUntil: 'networkidle2', timeout: 30000 });
  await page.waitForFunction(() => typeof D !== 'undefined' && D && D.employees.length > 0, { timeout: 20000 });
  await page.click('nav button[data-t="cal"]');

  async function shot(dept, label, file) {
    await page.click(`#dtabs button[data-d="${dept}"]`);
    await page.select('#cs', '');
    await sleep(600);
    const info = await page.evaluate((label) => {
      const wrap = document.querySelector('.calwrap');
      const row = [...document.querySelectorAll('#calendar tbody tr')].find(tr => {
        const n = tr.querySelector('td.name');
        return n && n.textContent.includes(label);
      });
      if (!row) return { found: false };
      // прокрутить контейнер так, чтобы строка была видна, и влево
      wrap.scrollTop = row.offsetTop - wrap.offsetTop - 80;
      wrap.scrollLeft = 0;
      const cells = [...row.querySelectorAll('td.day')].map(td => {
        const bg = getComputedStyle(td).backgroundColor;
        if (!/O|D|B|U/.test(td.className)) return null;
        const base = new Date(2027, 0, 1); base.setDate(base.getDate() + Number(td.dataset.d));
        const iso = base.toISOString().slice(0, 10);
        return iso + ' [' + td.className.replace('day','').trim() + '] ' + bg;
      }).filter(Boolean);
      return { found: true, cells };
    }, label);
    console.log('=== ' + dept + ' / ' + label + ' ===');
    console.log(info.found ? info.cells.join('\n') : 'НЕ НАЙДЕН');
    await sleep(300);
    await page.screenshot({ path: file });
    return info;
  }

  await shot('Админ_общий', 'Пархимович', 'C:\\VacationDashboard\\data\\pankhimovich.png');
  await shot('ГП56', 'Морозов', 'C:\\VacationDashboard\\data\\morozov.png');

  await browser.close();
  console.log('DONE');
})().catch(e => { console.error('ERR', e); process.exit(1); });
