const puppeteer = require('puppeteer-core');
const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const browser = await puppeteer.launch({
    executablePath: EDGE, headless: 'new', args: ['--no-sandbox', '--disable-gpu'],
    defaultViewport: { width: 1680, height: 900 },
  });
  const page = await browser.newPage();
  page.on('pageerror', e => console.log('[pageerror]', e.message));
  page.on('console', m => { if (m.type() === 'error') console.log('[console.error]', m.text()); });
  await page.authenticate({ username: 'admin', password: '123456nN!' });
  await page.goto('http://localhost:8086/', { waitUntil: 'networkidle2', timeout: 30000 });
  await page.waitForFunction(() => typeof D !== 'undefined' && D && D.employees.length > 0, { timeout: 20000 });

  await page.click('nav button[data-t="exp"]');
  await sleep(400);

  const exsuOptions = await page.$$eval('#exsu option', os => os.length);

  // Word по одному подразделению
  await page.click('#bWord');
  await sleep(300);
  const word = await page.evaluate(() => {
    const a = document.getElementById('wordLink');
    return { ready: a.classList.contains('ready'), href: a.href, download: a.download, status: document.getElementById('wordSt').textContent };
  });
  const wordText = decodeURIComponent(word.href.split(',').slice(1).join(','));
  console.log('=== WORD (одно подразделение) ===');
  console.log('exsu options:', exsuOptions);
  console.log('ready:', word.ready, '| file:', word.download);
  console.log('есть "ЯНВАРЬ":', wordText.includes('ЯНВАРЬ'), '| есть <table>:', wordText.includes('<table>'), '| есть "Согласовано":', wordText.includes('Согласовано'));
  console.log('фрагмент:', wordText.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 260));

  // Word по всем
  await page.click('#bWordAll');
  await sleep(300);
  const wall = await page.evaluate(() => {
    const a = document.getElementById('wordAllLink');
    return { ready: a.classList.contains('ready'), download: a.download, len: a.href.length };
  });
  const wallText = decodeURIComponent(await page.evaluate(() => document.getElementById('wordAllLink').href).then(h => h.split(',').slice(1).join(',')));
  const pageBreaks = (wallText.match(/page-break-before:always/g) || []).length;
  console.log('=== WORD (все подразделения) ===');
  console.log('ready:', wall.ready, '| file:', wall.download);
  console.log('страниц (page-break):', pageBreaks, '| всего символов:', wallText.length);

  // Excel
  await page.click('#bXls');
  await sleep(300);
  const xls = await page.evaluate(() => {
    const a = document.getElementById('xlsLink');
    return { ready: a.classList.contains('ready'), download: a.download, href: a.href };
  });
  const xlsText = decodeURIComponent(xls.href.split(',').slice(1).join(','));
  console.log('=== EXCEL ===');
  console.log('ready:', xls.ready, '| file:', xls.download);
  console.log('Workbook:', xlsText.includes('<Workbook'), '| Worksheet:', (xlsText.match(/<Worksheet /g) || []).length, '| Свод:', xlsText.includes('Свод пересечений'));

  // Backup
  const backup = await page.evaluate(() => {
    const a = document.querySelector('#exp a[href="/api/backup"]');
    return a ? a.getAttribute('href') : null;
  });
  console.log('=== BACKUP ===');
  console.log('ссылка:', backup);

  await page.screenshot({ path: 'C:\\VacationDashboard\\data\\export_tab.png', fullPage: true });
  await browser.close();
  console.log('DONE');
})().catch(e => { console.error('ERR', e); process.exit(1); });
