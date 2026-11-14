(() => {
  'use strict';
  const PALETTE = ['#f59e0b', '#38bdf8', '#22d3a6', '#a78bfa', '#f472b6', '#facc15'];
  const GROUPS = window.PIBENCH_GROUPS;
  const CATALOG_ORDER = Object.keys(window.PIBENCH_METRICS);
  const defOf = window.pibenchMetricDef;

  const $ = (s, el = document) => el.querySelector(s);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  let runs = [];
  let selected = [];   // run ids, order matters (first = baseline)
  const params = new URLSearchParams(location.search);

  // ---------- formatting ----------
  function fmt(v, unit) {
    if (v == null || !Number.isFinite(v)) return '—';
    const dec = (d) => v.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d });
    switch (unit) {
      case 'IOPS': case 'TPS': case 'events/s': return v >= 100 ? dec(0) : dec(1);
      case 'MB/s': return v >= 100 ? dec(0) : dec(1);
      case 's': return v < 1 ? dec(3) : v < 10 ? dec(2) : dec(1);
      case 'ms': case 'µs': return v < 100 ? dec(1) : dec(0);
      case '°C': return dec(1);
      default: return v >= 100 ? dec(0) : dec(2);
    }
  }
  function prettyLabel(l) {
    return String(l)
      .replace(/[-_]+/g, ' ')
      .replace(/\bsd\b/gi, 'SD').replace(/\bnvme\b/gi, 'NVMe').replace(/\bssd\b/gi, 'SSD').replace(/\busb\b/gi, 'USB')
      .replace(/\bgen ?(\d)\b/gi, 'Gen $1')
      .replace(/^\w/, (c) => c.toUpperCase());
  }
  const fmtRatio = (r) => (r >= 10 ? r.toFixed(0) : r.toFixed(1)) + '×';

  function compare(def, base, v) {
    if (base == null || v == null || !Number.isFinite(base) || !Number.isFinite(v)) return null;
    const mode = def.compare || 'ratio';
    if (mode === 'delta') {
      const d = v - base;
      if (Math.abs(d) < 1) return { cls: 'same', text: '≈ same', big: '≈', word: 'no change' };
      const good = def.better === 'lower' ? d < 0 : d > 0;
      return { cls: good ? 'good' : 'bad', text: `${d > 0 ? '+' : '−'}${Math.abs(d).toFixed(1)}°`, big: `${d > 0 ? '+' : '−'}${Math.abs(d).toFixed(1)}°C`, word: d > 0 ? 'hotter' : 'cooler' };
    }
    if (base === 0) return null;
    if (mode === 'control') {
      const pct = ((v - base) / base) * 100;
      if (Math.abs(pct) < 3) return { cls: 'neutral', text: 'same ✓', big: 'same', word: 'as expected' };
      return { cls: 'neutral', text: `${pct > 0 ? '+' : ''}${pct.toFixed(0)}%`, big: `${pct.toFixed(0)}%`, word: 'difference' };
    }
    if (v === 0) return null;
    const r = def.better === 'lower' ? base / v : v / base;
    if (r >= 0.95 && r <= 1.05) return { cls: 'same', text: '≈ same', big: '≈1×', word: 'no change' };
    if (r > 1) return { cls: 'good', text: fmtRatio(r), big: fmtRatio(r), word: 'faster' };
    return { cls: 'bad', text: fmtRatio(r), big: fmtRatio(r), word: 'slower' };
  }

  // ---------- data ----------
  async function load() {
    try {
      const res = await fetch('api/runs', { headers: { Accept: 'application/json' } });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      runs = await res.json();
    } catch (e) {
      $('#main').innerHTML = `<div class="empty">Could not load runs (${esc(e.message)}).</div>`;
      return;
    }
    const fromUrl = (params.get('runs') || '').split(',').map(Number).filter((id) => runs.some((r) => r.id === id));
    selected = fromUrl.length ? fromUrl : defaultSelection();
    if (params.get('present') === '1') document.body.classList.add('present');
    render();
  }
  function defaultSelection() {
    // latest run of each label, in chronological order, max 4
    const latest = new Map();
    for (const r of runs) latest.set(r.label, r);
    return [...latest.values()].sort((a, b) => new Date(a.captured_at) - new Date(b.captured_at)).slice(0, 4).map((r) => r.id);
  }
  // colour follows the LABEL (first-seen order), so 'sd-card' keeps the same colour in every clip
  const colorOf = (id) => {
    const labels = [...new Set(runs.map((r) => r.label))];
    const run = runs.find((r) => r.id === id);
    return PALETTE[Math.max(0, labels.indexOf(run && run.label)) % PALETTE.length];
  };

  function syncUrl() {
    const p = new URLSearchParams();
    if (selected.length) p.set('runs', selected.join(','));
    if (document.body.classList.contains('present')) p.set('present', '1');
    const qs = p.toString();
    history.replaceState(null, '', location.pathname + (qs ? '?' + qs : ''));
  }

  // ---------- render ----------
  function render() {
    renderChips();
    syncUrl();
    const main = $('#main');
    if (!runs.length) {
      main.innerHTML = `<div class="empty"><p>No runs yet. On the Pi:</p>
<pre>sudo ./pibench-run.sh --label sd-card
# ...or upload a saved result
./pibench-run.sh --upload results/&lt;file&gt;.json</pre></div>`;
      return;
    }
    const sel = selected.map((id) => runs.find((r) => r.id === id)).filter(Boolean);
    if (!sel.length) { main.innerHTML = '<div class="empty">Select one or more runs above.</div>'; return; }

    main.innerHTML = heroHtml(sel) + groupsHtml(sel) + systemHtml(sel);
    replay();
  }

  function renderChips() {
    $('#chips').innerHTML = runs.map((r) => {
      const idx = selected.indexOf(r.id);
      const on = idx >= 0;
      const d = new Date(r.captured_at);
      const disk = r.system?.disk_type === 'nvme' && r.system?.pcie_gen ? `NVMe Gen${r.system.pcie_gen}` : (r.system?.disk_type || '');
      return `<div class="chip ${on ? 'on' : ''}" data-id="${r.id}" style="--c:${on ? colorOf(r.id) : 'transparent'}">
        <span class="dot"></span>
        <span class="lbl">${esc(r.label)}</span>
        <span class="meta">#${r.id} · ${d.toLocaleDateString(undefined, { day: '2-digit', month: 'short' })} ${d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}${disk ? ' · ' + esc(disk) : ''}</span>
        ${on ? `<span class="ord">${idx === 0 ? 'BASE' : idx + 1}</span>` : ''}
      </div>`;
    }).join('');
  }

  function heroHtml(sel) {
    const base = sel[0], last = sel[sel.length - 1];
    const journey = sel.map((r, i) => `<span class="step" style="--c:${colorOf(r.id)}">${esc(prettyLabel(r.label))}</span>${i < sel.length - 1 ? '<span class="arrow">→</span>' : ''}`).join('');
    const keys = Object.entries(window.PIBENCH_METRICS).filter(([, d]) => d.headline).sort((a, b) => a[1].headline - b[1].headline).map(([k]) => k);
    const cards = keys.map((k) => {
      const def = defOf(k);
      const b = base.metrics?.[k], v = last.metrics?.[k];
      if (sel.length === 1) {
        if (b == null) return '';
        return `<div class="hcard" style="--accent:${colorOf(base.id)}"><div class="t">${esc(def.label)}</div>
          <div class="big">${fmt(b, def.unit)}<small>${esc(def.unit)}</small></div><div class="ft">${esc(def.hint || '')}</div></div>`;
      }
      const c = compare(def, b, v);
      if (!c) return '';
      const accent = c.cls === 'good' ? 'var(--good)' : c.cls === 'bad' ? 'var(--bad)' : 'var(--neutral)';
      return `<div class="hcard" style="--accent:${accent}"><div class="t">${esc(def.label)}</div>
        <div class="big">${esc(c.big)}<small>${esc(c.word)}</small></div>
        <div class="ft">${fmt(b, def.unit)} → ${fmt(v, def.unit)} ${esc(def.unit)}</div></div>`;
    }).join('');
    return `<section class="hero"><div class="journey">${journey}</div><div class="headlines">${cards}</div></section>`;
  }

  function groupsHtml(sel) {
    const keys = new Set();
    sel.forEach((r) => Object.keys(r.metrics || {}).forEach((k) => keys.add(k)));
    const ordered = [...keys].sort((a, b) => {
      const ia = CATALOG_ORDER.indexOf(a), ib = CATALOG_ORDER.indexOf(b);
      return (ia < 0 ? 999 : ia) - (ib < 0 ? 999 : ib) || a.localeCompare(b);
    });
    return GROUPS.map((g) => {
      const gk = ordered.filter((k) => defOf(k).group === g.id);
      if (!gk.length) return '';
      return `<section class="group"><div class="group-head"><h3>${esc(g.title)}</h3><p>${esc(g.blurb)}</p></div>
        <div class="cards">${gk.map((k) => cardHtml(k, sel)).join('')}</div></section>`;
    }).join('');
  }

  function cardHtml(key, sel) {
    const def = defOf(key);
    const vals = sel.map((r) => r.metrics?.[key]);
    const max = Math.max(...vals.filter((v) => Number.isFinite(v)), 0);
    const base = vals[0];
    const dir = def.compare === 'control' ? 'should not change' : def.better === 'lower' ? 'lower is better' : 'higher is better';
    const rows = sel.map((r, i) => {
      const v = vals[i];
      const pct = Number.isFinite(v) && max > 0 ? Math.max(1.5, (v / max) * 100) : 0;
      let badge = '<span class="badge base">—</span>';
      if (i === 0) badge = `<span class="badge base">${sel.length > 1 ? 'baseline' : ''}</span>`;
      else { const c = compare(def, base, v); if (c) badge = `<span class="badge ${c.cls}">${esc(c.text)}</span>`; }
      return `<div class="row" style="--c:${colorOf(r.id)}">
        <span class="rl" title="${esc(r.label)}">${esc(prettyLabel(r.label))}</span>
        <div class="track"><div class="bar" data-w="${pct.toFixed(2)}"></div></div>
        <span class="v ${Number.isFinite(v) ? '' : 'na'}" data-val="${Number.isFinite(v) ? v : ''}" data-unit="${esc(def.unit)}">${fmt(v, def.unit)}</span>
        ${badge}
      </div>`;
    }).join('');
    return `<div class="card"><div class="card-head"><div><div class="t">${esc(def.label)}</div>${def.hint ? `<div class="h">${esc(def.hint)}</div>` : ''}</div>
      <span class="u">${esc(def.unit)} · ${dir}</span></div>${rows}</div>`;
  }

  function systemHtml(sel) {
    const s = (r) => r.system || {};
    const rows = [
      ['Storage', (r) => [s(r).disk_type, s(r).disk_model, s(r).disk_size].filter(Boolean).join(' · ')],
      ['Root device', (r) => [s(r).root_source, s(r).filesystem].filter(Boolean).join(' · ')],
      ['PCIe link', (r) => s(r).pcie_link_speed ? `${s(r).pcie_link_speed} x${s(r).pcie_width ?? '?'} (Gen ${s(r).pcie_gen ?? '?'})` : '—'],
      ['PCIe config', (r) => s(r).pcie_config || (s(r).disk_type === 'nvme' ? 'default' : '—')],
      ['Board', (r) => [s(r).model, s(r).ram_mb ? `${s(r).ram_mb} MB` : ''].filter(Boolean).join(' · ')],
      ['OS / kernel', (r) => [s(r).os, s(r).kernel].filter(Boolean).join(' · ')],
      ['Throttled', (r) => [s(r).throttled_start, s(r).throttled_end].filter(Boolean).join(' → ') || '—'],
      ['Containers running', (r) => s(r).containers_running ?? '—'],
      ['Test settings', (r) => r.settings ? `${r.settings.iterations ?? '?'} iter · fio ${r.settings.fio_runtime_s ?? '?'}s × ${r.settings.fio_size ?? '?'} · ${Math.round(r.settings.duration_s || 0)}s total` : '—'],
      ['Captured', (r) => new Date(r.captured_at).toLocaleString()],
    ];
    const head = `<thead><tr><th></th>${sel.map((r) => `<td style="--c:${colorOf(r.id)}">${esc(prettyLabel(r.label))}</td>`).join('')}</tr></thead>`;
    const body = rows.map(([name, f]) => `<tr><th>${name}</th>${sel.map((r) => `<td>${esc(f(r))}</td>`).join('')}</tr>`).join('');
    const notes = sel.some((r) => r.notes) ? `<tr><th>Notes</th>${sel.map((r) => `<td class="notes">${esc(r.notes || '')}</td>`).join('')}</tr>` : '';
    return `<section class="group"><div class="group-head"><h3>Test setup</h3><p>Same board, same OS. Only the storage changes.</p></div>
      <table class="systable">${head}<tbody>${body}${notes}</tbody></table></section>`;
  }

  // ---------- animation ----------
  let rafId = 0;
  function replay() {
    const main = $('#main');
    cancelAnimationFrame(rafId);
    main.classList.remove('animate');
    main.querySelectorAll('.bar').forEach((b) => { b.style.transition = 'none'; b.style.width = '0'; });
    void main.offsetWidth; // reflow
    requestAnimationFrame(() => {
      main.classList.add('animate');
      main.querySelectorAll('.bar').forEach((b, i) => {
        b.style.transition = `width 1.3s cubic-bezier(.2,.8,.2,1) ${Math.min(i * 25, 600)}ms`;
        b.style.width = b.dataset.w + '%';
      });
      const nums = [...main.querySelectorAll('.v[data-val]')].filter((n) => n.dataset.val !== '');
      const t0 = performance.now(), dur = 1300;
      const tick = (t) => {
        const p = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - p, 3);
        nums.forEach((n) => { n.textContent = fmt(Number(n.dataset.val) * e, n.dataset.unit); });
        if (p < 1) rafId = requestAnimationFrame(tick);
      };
      rafId = requestAnimationFrame(tick);
    });
  }

  function togglePresent(force) {
    const on = document.body.classList.toggle('present', force);
    if (on && document.documentElement.requestFullscreen && !document.fullscreenElement) document.documentElement.requestFullscreen().catch(() => {});
    if (!on && document.fullscreenElement) document.exitFullscreen().catch(() => {});
    syncUrl();
    replay();
  }

  // ---------- events ----------
  $('#chips').addEventListener('click', (e) => {
    const chip = e.target.closest('.chip');
    if (!chip) return;
    const id = Number(chip.dataset.id);
    selected = selected.includes(id) ? selected.filter((x) => x !== id) : [...selected, id];
    render();
  });
  $('#btn-present').addEventListener('click', () => togglePresent(true));
  $('#btn-replay').addEventListener('click', replay);
  document.addEventListener('keydown', (e) => {
    if (e.target.closest('input, textarea')) return;
    if (e.key === 'p' || e.key === 'P') togglePresent();
    else if (e.key === 'r' || e.key === 'R') replay();
    else if (e.key === 'Escape' && document.body.classList.contains('present')) togglePresent(false);
  });
  document.addEventListener('fullscreenchange', () => {
    if (!document.fullscreenElement && document.body.classList.contains('present')) { document.body.classList.remove('present'); syncUrl(); }
  });

  load();
})();
