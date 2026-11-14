// Metric catalogue: how each key from the runner is labelled, grouped and compared.
// better: 'higher' | 'lower'   compare: 'ratio' (×N) | 'delta' (±diff) | 'control' (should not change)
window.PIBENCH_GROUPS = [
  { id: 'random',   title: 'Random 4K I/O',     blurb: 'Small, scattered reads and writes. This is what databases, Docker and package installs actually do.' },
  { id: 'seq',      title: 'Sequential I/O',    blurb: 'Big continuous transfers, like copying a video file or pulling a large image.' },
  { id: 'real',     title: 'Real-world tasks',  blurb: 'Wall-clock time for things you notice.' },
  { id: 'db',       title: 'PostgreSQL',        blurb: 'pgbench against the shared Postgres instance (throwaway database).' },
  { id: 'apps',     title: 'App response time', blurb: 'Median of 5 requests to self-hosted apps.' },
  { id: 'thermal',  title: 'Thermals',          blurb: 'Temperatures sampled every 2 s during the whole run.' },
  { id: 'control',  title: 'Control',           blurb: 'CPU-only test. It should NOT change, which shows the comparison is fair.' },
];

window.PIBENCH_METRICS = {
  fio_rand4k_read_qd1_iops:   { group: 'random', label: 'Random read 4K · QD1',  unit: 'IOPS', better: 'higher', headline: 1, hint: 'Single-threaded, like a typical app' },
  fio_rand4k_write_qd1_iops:  { group: 'random', label: 'Random write 4K · QD1', unit: 'IOPS', better: 'higher', headline: 2 },
  fio_rand4k_read_qd32_iops:  { group: 'random', label: 'Random read 4K · QD32', unit: 'IOPS', better: 'higher', hint: 'Many parallel requests' },
  fio_rand4k_write_qd32_iops: { group: 'random', label: 'Random write 4K · QD32',unit: 'IOPS', better: 'higher' },
  fio_rand4k_read_qd1_lat_us: { group: 'random', label: 'Read latency 4K · QD1', unit: 'µs',   better: 'lower' },

  fio_seq_read_mbps:          { group: 'seq', label: 'Sequential read',  unit: 'MB/s', better: 'higher', headline: 3 },
  fio_seq_write_mbps:         { group: 'seq', label: 'Sequential write', unit: 'MB/s', better: 'higher' },
  hdparm_read_mbps:           { group: 'seq', label: 'hdparm read',      unit: 'MB/s', better: 'higher', hint: 'Quick classic disk read test' },

  boot_total_s:               { group: 'real', label: 'Boot time',               unit: 's', better: 'lower', headline: 5, hint: 'systemd-analyze, kernel + userspace' },
  boot_userspace_s:           { group: 'real', label: 'Boot · userspace',        unit: 's', better: 'lower' },
  docker_run_s:               { group: 'real', label: 'Start a container',       unit: 's', better: 'lower', hint: 'docker run --rm alpine true' },
  docker_restart_s:           { group: 'real', label: 'Restart app containers',  unit: 's', better: 'lower' },
  smallfiles_write_s:         { group: 'real', label: 'Write 5,000 small files', unit: 's', better: 'lower' },
  smallfiles_read_s:          { group: 'real', label: 'Read 5,000 small files',  unit: 's', better: 'lower', hint: 'Cold cache' },
  smallfiles_delete_s:        { group: 'real', label: 'Delete 5,000 small files',unit: 's', better: 'lower' },

  pgbench_tps:                { group: 'db', label: 'pgbench read/write',  unit: 'TPS', better: 'higher', headline: 4, hint: 'TPC-B-like, 8 clients' },
  pgbench_select_tps:         { group: 'db', label: 'pgbench read-only',   unit: 'TPS', better: 'higher' },
  pgbench_init_s:             { group: 'db', label: 'Load 2M-row dataset', unit: 's',   better: 'lower', hint: 'pgbench -i -s 20' },

  cpu_temp_idle_c:            { group: 'thermal', label: 'CPU idle',  unit: '°C', better: 'lower', compare: 'delta' },
  cpu_temp_max_c:             { group: 'thermal', label: 'CPU peak',  unit: '°C', better: 'lower', compare: 'delta' },
  nvme_temp_idle_c:           { group: 'thermal', label: 'SSD idle',  unit: '°C', better: 'lower', compare: 'delta' },
  nvme_temp_max_c:            { group: 'thermal', label: 'SSD peak',  unit: '°C', better: 'lower', compare: 'delta' },

  cpu_sysbench_eps:           { group: 'control', label: 'CPU (sysbench)', unit: 'events/s', better: 'higher', compare: 'control' },
};

// Dynamic keys, e.g. "url_ms:https://apps.tinyserverlab.in/inventory/"
window.pibenchMetricDef = function (key) {
  if (window.PIBENCH_METRICS[key]) return window.PIBENCH_METRICS[key];
  if (key.startsWith('url_ms:')) {
    let label = key.slice(7);
    try { const u = new URL(label); label = u.host + u.pathname.replace(/\/$/, ''); } catch (_) {}
    return { group: 'apps', label, unit: 'ms', better: 'lower' };
  }
  return { group: 'control', label: key, unit: '', better: 'higher', compare: 'control' };
};
