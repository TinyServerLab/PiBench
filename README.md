# PiBench: before/after storage benchmark for the TinyServerLab Pi 5

PiBench has two parts:

| Part | Where it runs | What it does |
|---|---|---|
| `runner/pibench-run.sh` | on the Pi host (not in Docker) | Runs the tests and saves a JSON file to `runner/results/`. It can also upload the file to the dashboard. |
| `app/` + `docker-compose.yml` | Docker, at `https://apps.tinyserverlab.in/pibench/` | Shows a side-by-side comparison, with a presentation mode for recording. |

The runner works without the dashboard. **Capture the SD card baseline first.** You can deploy the dashboard and upload results at any time later.

---

## 1. Capture the SD card baseline now (before installing the HAT)

```bash
# on the Pi
sudo apt install -y fio jq hdparm sysbench curl
cd ~/pibench/runner
cp pibench.env.example pibench.env      # set PIBENCH_PG_CONTAINER / admin user if different
chmod +x pibench-run.sh

sudo reboot                             # clean boot -> meaningful boot-time number
# ...after it's back up and your containers have settled (~2 min):
sudo ./pibench-run.sh --label sd-card --no-upload --notes "Stock SD card, all apps running"
```

* A full run takes about 10–15 minutes on an SD card (3 iterations). For a quick dry run, use `--quick` (about 4 minutes).
* The result is saved to `runner/results/<timestamp>_sd-card.json`. **Keep this file.** When you clone the SD card to the SSD, the file goes with it.
* For extra safety, also copy the file to your PC: `scp pi@<pi>:~/pibench/runner/results/*.json .`

### What it measures

| Group | Tests |
|---|---|
| Random 4K | fio random read/write at QD1 and QD32 (IOPS), plus QD1 read latency |
| Sequential | fio 1M read/write (MB/s), plus `hdparm -t` |
| Real-world | boot time (`systemd-analyze`), `docker run` start time, writing/reading/deleting 5,000 small files |
| PostgreSQL | `pgbench` init + read/write + read-only TPS. Uses a **throwaway** `pibench_pgbench_db` database that is dropped afterwards. No other database is touched. |
| App latency | optional: set `PIBENCH_URLS` in `pibench.env` |
| Thermals | CPU and NVMe temperature, idle and peak (sampled every 2 s), plus throttle flags |
| Control | `sysbench cpu`. This should stay the same in every run, which shows only the storage changed. |

Each test runs `--iterations` times (default 3), and the **median** is reported. The raw samples are kept in the JSON file.

---

## 2. Deploy the dashboard (any time)

```bash
cd ~/pibench
cp .env.example .env
#  - SHARED_NETWORK: the network that Caddy + shared-postgres are on
#      docker inspect shared-postgres -f '{{json .NetworkSettings.Networks}}'
#  - DB_PASSWORD and INGEST_TOKEN:  openssl rand -hex 24

# One-time: create the role + database on the shared Postgres (touches nothing else)
docker exec -i shared-postgres psql -U postgres -v pw='<DB_PASSWORD from .env>' < db/init.sql

docker compose up -d --build
docker logs pibench          # -> "schema ready", "listening on :3000, base path /pibench"
```

Add `caddy/Caddyfile.snippet` to your `apps.tinyserverlab.in` site block and reload Caddy:

```bash
docker exec <caddy-container> caddy reload --config /etc/caddy/Caddyfile
```

Then put the same `INGEST_TOKEN` into `runner/pibench.env` as `PIBENCH_TOKEN` and upload the baseline:

```bash
./runner/pibench-run.sh --upload runner/results/*_sd-card.json
```

The dashboard is read-only for visitors. Uploading, renaming and deleting all need the token. If you'd rather keep it off the public internet between recordings, put it behind Cloudflare Access.

---

## 3. After the upgrade

1. Clone the SD card to the NVMe (for example with `rpi-clone`, or SD Card Copier), then set the boot order to NVMe first.
2. **Run 2: PCIe Gen 2 (default)**
   ```bash
   sudo reboot
   sudo ./pibench-run.sh --label nvme-gen2 --notes "M.2 HAT compact, 512GB, PCIe Gen2"
   ```
3. **Run 3: PCIe Gen 3.** Add `dtparam=pciex1_gen=3` to `/boot/firmware/config.txt`, then:
   ```bash
   sudo reboot
   sudo ./pibench-run.sh --label nvme-gen3 --notes "Same SSD, PCIe Gen3"
   ```
   The dashboard's "Test setup" table shows the actual negotiated link (`5.0 GT/s` = Gen 2, `8.0 GT/s` = Gen 3), read from sysfs.

### Keep it fair
* Same containers running in every run (the runner records how many). Stop anything doing heavy background work.
* Same case, cooling and power supply. If throttle flags aren't `0x0`, the run is suspect.
* Reboot before each run, so the boot time is measured fresh.

---

## 4. Recording tips

* Run the benchmark in a large terminal font. The coloured `✔ metric value (samples)` lines read well on camera.
* On the dashboard, click the runs in the order you want: **the first one clicked is the baseline**. Each label keeps the same colour in every clip (SD card is amber).
* **P** = presentation mode (fullscreen, larger text, controls hidden). **R** = replay the bar and number animation, so you can do several takes. **Esc** = exit.
* You can bookmark exact views: `.../pibench/?runs=1,3&present=1` (SD vs Gen 3) or `?runs=1,2,3&present=1` (the full story).

### API (for scripting)
```
GET    /pibench/api/runs            list runs (no raw samples)
GET    /pibench/api/runs/:id        one run incl. samples
POST   /pibench/api/runs            Bearer token, body = runner JSON
PATCH  /pibench/api/runs/:id        Bearer token, {"label": "...", "notes": "..."}
DELETE /pibench/api/runs/:id        Bearer token
GET    /pibench/healthz
```
