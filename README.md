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


### NVMe validation and configuration
Step 1: Check the SSD is detected

You have the official M.2 HAT+ Compact. It conforms to the Raspberry Pi HAT+ specification, which allows Raspberry Pi OS to automatically detect the HAT+ and any connected devices, so you don’t need to change config.txt or add PCIE_PROBE. 
raspberrypi


```bash
sudo apt update && sudo apt full-upgrade -y && sudo rpi-eeprom-update -a   # latest bootloader, then reboot if it updated
lsblk                                   # expect: nvme0n1  476.9G
dmesg | grep -i nvme | head             # no errors / timeouts
cat /sys/class/nvme/nvme0/device/current_link_speed   # 5.0 GT/s = Gen 2 (default)
sudo apt install -y nvme-cli && sudo nvme smart-log /dev/nvme0n1 | head -15   # critical_warning 0, sane temperature
```
If nvme0n1 doesn’t show up, power off and reseat the ribbon cable at both ends. The contacts must face the correct side on each end.

Step 2: Clone the SD card to the SSD

Use Jeff Geerling’s maintained fork of rpi-clone. It copies the system, grows the partition to fill the whole 512 GB, and updates the boot references (PARTUUIDs) in the copy’s fstab and cmdline.txt so they point at the SSD.

```bash
curl https://raw.githubusercontent.com/geerlingguy/rpi-clone/master/install | sudo bash

# Stop anything writing to disk so Postgres is copied in a consistent state
sudo systemctl stop docker docker.socket
sudo rpi-clone nvme0n1        # answer the prompts; this ERASES the SSD (fine, it's new)
sudo systemctl start docker
```
Stopping Docker takes your apps offline for the few minutes the clone runs.

Step 3: Check the clone before switching
```bash
sudo mount /dev/nvme0n1p2 /mnt && sudo mount /dev/nvme0n1p1 /mnt/boot/firmware
sudo blkid /dev/nvme0n1p1 /dev/nvme0n1p2          # note the PARTUUIDs
grep PARTUUID /mnt/etc/fstab /mnt/boot/firmware/cmdline.txt   # must match the nvme ones above
ls /mnt/var/lib/docker /mnt/home/$USER/pibench/runner/results  # data + baseline came across
sudo umount /mnt/boot/firmware /mnt
```
Step 4: Change the boot order

Pick one of these:

```bash
sudo raspi-config   # Advanced Options > Boot Order > NVMe/USB Boot
```
or edit the bootloader setting directly:

```bash
sudo rpi-eeprom-config --edit
# set:  BOOT_ORDER=0xf416
```
The digits are read right to left. The 6 at the end is what tells the Pi to attempt NVMe boot first, then it tries the SD card (1), then USB (4). 
jeffgeerling

Leave the SD card in for the first boot. If the NVMe boot fails, the Pi falls back to the SD card and you’re back where you started.

Step 5: Reboot and confirm you’re running from the SSD
```bash
sudo reboot
findmnt /           # SOURCE must be /dev/nvme0n1p2  (not mmcblk0p2)
docker ps           # all containers up
curl -I https://apps.tinyserverlab.in/inventory/
```
Once it’s confirmed, run the “after” benchmark:

```bash
sudo ./pibench-run.sh --label nvme-gen2 --notes "M.2 HAT+ Compact, 512GB, Gen2"
```