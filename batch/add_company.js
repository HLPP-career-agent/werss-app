import fs from "node:fs";

// 占位符由 process_chunk.py / canary.py 注入:
//   __COMPANY__  JSON: {company_id, name, short, code}
//   __MODE__     "add" | "canary" (canary 只搜索不添加,用于风控探测)
//   __SPACE_FILE__  本 worker 的 taskSpace id 存放路径
//   __SPACE_NAME__  本 worker 的 taskSpace 名称
//   __APP_URL__     we-mp-rss 地址
//   __ADMIN_USER__ / __ADMIN_PASS__  管理端登录凭据(来自 config.env)
const company = __COMPANY__;
const mode = "__MODE__";
const spaceFile = "__SPACE_FILE__";
const spaceName = "__SPACE_NAME__";
const appUrl = "__APP_URL__";
const adminUser = "__ADMIN_USER__";
const adminPass = "__ADMIN_PASS__";

function result(o) { console.log("RESULT:" + JSON.stringify(o)); }

// ---- 空间管理:每个 worker 复用自己的 space ----
let task;
try {
  const id = parseInt((fs.readFileSync(spaceFile, "utf8") || "").trim());
  if (!id) throw new Error("no id");
  task = await taskSpace(id);
} catch (e) {
  task = await taskSpace(spaceName);
  try { fs.writeFileSync(spaceFile, String(task.spaceId)); } catch {}
}
let page = null;
const existingPages = await task.pages();
page = existingPages.length ? existingPages[existingPages.length - 1] : await task.newPage();

async function ensureApp() {
  // 复用已有页面(防页面预算耗尽);导航失败才关旧换新
  let ok = false;
  for (let attempt = 0; attempt < 2 && !ok; attempt++) {
    try {
      await page.goto(appUrl);
      await page.waitForLoadState();
      ok = await page.evaluate(() => document.readyState === "complete");
    } catch (e) {
      ok = false;
    }
    if (!ok && attempt === 0) {
      try { await page.close().catch(() => {}); } catch {}
      page = await task.newPage();
    }
  }
  if (!ok) throw new Error("app page navigation failed twice");
  await page.waitForTimeout(1800);
  const loginVisible = await page.evaluate(
    () => !!document.querySelector("input[placeholder='请输入帐号']")
  );
  if (loginVisible) {
    await page.fill("input[placeholder='请输入帐号']", adminUser);
    await page.fill("input[placeholder='请输入密码']", adminPass);
    await page.click("loc=role:button[name='登录']");
    await page.waitForTimeout(3500);
  }
}

// ---- 候选搜索词:短名、短名+招聘、去掉法务后缀的全名、全名+招聘 ----
function clean(s) {
  return (s || "")
    .replace(/[\s*＊]/g, "")
    .replace(/^(SST|ST|ＳＴ)/i, "")
    .replace(/A$/, "");
}
function buildCandidates() {
  const s = clean(company.short);
  const base = (company.name || "").replace(/(控股集团|集团|控股)?股份有限公司$/, "").replace(/(集团|控股)?有限公司$/, "");
  const out = [];
  for (const x of [s + "招聘", s, base + "招聘", base]) {
    if (x && x.length >= 2 && !out.includes(x)) out.push(x);
  }
  return out;
}

// ---- 归一化:全角→半角 + 繁→简(映射表由 process_chunk/canary 注入路径,来自台账词表) ----
// 教训:港股台账用繁体+全角(星光集團/ＳＯＨＯ中國),公众号名几乎全是简体+半角
// (星光集团有限公司/SOHO中国)。微信搜索能兜住繁体(首条即正确账号),但本地
// includes() 匹配必须两侧归一,否则港交所队列命中率 0%。
let T2S = {};
try { T2S = JSON.parse(fs.readFileSync("__T2S_FILE__", "utf8")); } catch (e) {}
function norm(s) {
  if (!s) return "";
  let out = "";
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (c >= 0xff01 && c <= 0xff5e) out += String.fromCharCode(c - 0xfee0);
    else out += T2S[ch] || ch;
  }
  return out.toLowerCase();
}

// 某个公众号名是否匹配核心词:归一化后去掉核心词,剩余部分只能是中性修饰词
// (有限 补进宽容表:账号常叫「XX有限公司」,而「有限」不在原来在的词表里)
function isMatch(opt, core) {
  const o = norm(opt), c = norm(core);
  if (!o.includes(c)) return false;
  const rest = o.split(c).join("");
  return /^(招聘|有限|集团|股份|控股|公司|官方|招聘号|招聘平台|招聘中心|招聘官方号|号|平台|中心|[a-z0-9])*$/.test(rest);
}

async function openDialog() {
  await page.evaluate(() => {
    const b = [...document.querySelectorAll("button")].find(
      (x) => x.textContent.trim() === "订阅" && x.getClientRects().length
    );
    b && b.click();
  });
  await page.waitForTimeout(600);
  await page.evaluate(() => {
    const items = [...document.querySelectorAll("li, .arco-dropdown-option")].filter(
      (x) => x.textContent.trim() === "添加公众号" && x.getClientRects().length
    );
    items[0] && items[0].click();
  });
  await page.waitForSelector("input[placeholder='请输入公众号名称']", { state: "visible", timeout: 8000 });
  await page.waitForTimeout(400);
}

async function readOptions(kw) {
  // 读两次,避免读到加载中的空列表
  const read = () =>
    page.evaluate(() => {
      const pops = [...document.querySelectorAll(".arco-trigger-popup")].filter(
        (p) =>
          p.getClientRects().length &&
          !p.textContent.includes("English") && // 排除语言选择下拉
          (p.querySelector(".arco-select-option") || p.querySelector(".arco-select-dropdown"))
      );
      const p = pops[pops.length - 1];
      if (!p) return null;
      return [...p.querySelectorAll(".arco-select-option")].map((o) => o.textContent.trim());
    });
  let opts = await read();
  if (opts === null || opts.length === 0) {
    await page.waitForTimeout(1300);
    opts = await read();
  }
  return opts || null;
}

async function searchOptions(kw) {
  await page.click("input[placeholder='请输入公众号名称']");
  await page.waitForTimeout(250);
  await page.keyboard.press("ControlOrMeta+a");
  await page.keyboard.press("Delete");
  await page.keyboard.type(kw);
  for (let t = 0; t < 8; t++) {
    await page.waitForTimeout(800);
    const opts = await readOptions(kw);
    if (opts !== null && opts.length >= 0 && opts !== undefined) {
      if (opts.length > 0) return opts;
      if (t >= 3) return []; // 弹层在但始终为空 = 无结果
    }
  }
  return [];
}

async function pickAndSubmit(target) {
  const clicked = await page.evaluate((t) => {
    const pops = [...document.querySelectorAll(".arco-trigger-popup")].filter((p) => p.getClientRects().length);
    for (const p of pops) {
      const el = [...p.querySelectorAll(".arco-select-option")].find((o) => o.textContent.trim() === t);
      if (el) { el.click(); return true; }
    }
    return false;
  }, target);
  if (!clicked) return false;
  await page.waitForTimeout(900);
  const ok = await page.evaluate(() => !!document.querySelector("input[placeholder='请输入公众号ID']")?.value);
  if (!ok) return false;
  await page.click("loc=role:button[name='添加订阅']");
  for (let t = 0; t < 12; t++) {
    await page.waitForTimeout(700);
    const gone = await page.evaluate(() => !document.querySelector("input[placeholder='请输入公众号名称']"));
    if (gone) return true;
  }
  return true;
}

async function closeDialog() {
  await page.keyboard.press("Escape");
  await page.waitForTimeout(400);
  await page.evaluate(() => {
    const btns = [...document.querySelectorAll(".arco-modal button")].filter(
      (x) => x.getClientRects().length && /取\s*消/.test(x.textContent)
    );
    btns[0] && btns[0].click();
  });
  await page.waitForTimeout(400);
}

// ---- 主流程 ----
try {
  await ensureApp();

  if (mode === "canary") {
    await openDialog();
    // 用注入的轮换词（process_chunk.next_canary_kw 从池里取），避免固定词被应用/微信缓存造成假阳性
    const opts = await searchOptions(company.short || "平安银行");
    await closeDialog();
    result({ status: "canary", found: (opts || []).length });
    process.exit(0);
  }

  const cands = buildCandidates();
  const tried = [];
  let picked = null;

  await openDialog();
  for (const cand of cands) {
    tried.push(cand);
    const opts = await searchOptions(cand);
    if (!opts || opts.length === 0) continue;
    const core = cand.replace(/招聘$/, "");
    const matches = opts.filter((o) => isMatch(o, core));
    if (matches.length === 0) continue;
    // 选择优先级:带「招聘」的归一匹配(招聘号优先,最短者) > 归一化完全相等 > 最短归一匹配。
    // 兜底取最短:繁体关键词搜回的账号名常带「有限公司」等后缀(星光集團→星光集团有限公司),
    // 旧逻辑只认完全相等会放走唯一正确账号。
    const withZp = matches.filter((o) => o.includes("招聘"));
    const exact = matches.find((o) => norm(o) === norm(core));
    const shortest = matches.slice().sort((a, b) => norm(a).length - norm(b).length)[0];
    const target = withZp.sort((a, b) => a.length - b.length)[0] || exact || shortest || null;
    if (target) { picked = target; break; }
  }

  let status = "not_found", name = "";
  if (picked) {
    const ok = await pickAndSubmit(picked);
    status = ok ? "added" : "submit_failed";
    name = picked;
  }
  await closeDialog();
  result({ status, name, tried, company_id: company.company_id });
} catch (err) {
  result({ status: "JS_ERROR", detail: String(err).slice(0, 200), company_id: company.company_id });
}
