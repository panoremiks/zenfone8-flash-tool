# zenfone8-flash-tool

Fastboot installer for A/B dynamic-partition ROMs on the **ASUS ZenFone 8
(ASUS_I006D)** with a **locked bootloader**, using a `vbmeta` image signed with
your own AVB key.

[![Preview](https://img.youtube.com/vi/Tce4X4LHVbA/0.jpg)](https://youtu.be/Tce4X4LHVbA)

---

## The key mechanism

The bootloader accepts a **user-supplied AVB public key** through the
`avb_custom_key` fastboot target, **while the bootloader is still locked**.

The key is not written to a normal flashable partition. The bootloader hands it
to the **Trusted Execution Environment**, which keeps it in **RPMB-backed device
information**:

- it **survives reboots, partition flashes and full firmware reflashes**;
- registering it works on a **locked** bootloader, without
  `fastboot flashing unlock`.

This tool uses the key **only to sign `vbmeta`** by default. It does **not** write
`avb_custom_key` unless you pass `--register-key` — the device either already
trusts the key, or you register it once explicitly. Overwriting the trusted key
in RPMB can make previously working firmware unbootable.

What this enables:

- **booting images signed with your own key on a locked device**;
- installing a custom ROM without unlocking: the ROM's `vbmeta` is re-signed
  with your key and `flags=3` (verification disabled);
- keeping the bootloader state "locked" while controlling the boot chain.

What it does **not** do:

- it does not turn verified boot green — the device reports a **yellow** state,
  so hardware-backed attestation (Play Integrity, some DRM) will not report a
  pristine device;
- it does not unlock the bootloader or bypass the OEM unlock gate.

---

## Which ROMs can it install?

The tool installs a **different operating system** — a custom ROM instead of the
vendor firmware — but the ROM must be built for the **same Android release and
vendor level as the firmware currently installed on the target device**.

Why this constraint exists:

- The script replaces only the **OS side** of the device: `boot`, `vendor_boot`,
  `dtbo`, `vbmeta`, `vbmeta_system`, and the logical partitions `system`,
  `vendor`, `product`, `system_ext`, `odm` inside `super`.
- It does **not** touch the low-level firmware: bootloader, TZ, hyp, aop, devcfg,
  modem, DSP, bluetooth, keymaster and the other boot-chain partitions stay
  exactly as the vendor shipped them.
- That firmware is the other half of the contract. The new framework talks to it
  through VINTF/HAL interfaces, and the new kernel (inside `boot`/`vendor_boot`)
  has to match the interfaces and modules that firmware provides.
- A ROM built for a newer Android release expects newer HAL versions, newer
  kernel interfaces and a vendor image that go with them. On older firmware the
  handshake fails and the device does not reach the boot animation — it hangs or
  reboots, even though every flash succeeded.

In short: "custom ROM" does not mean "any Android version". The ROM's Android
release has to match the firmware that stays on the device.

### Tested combination

| ROM package | Firmware already on the device | Result |
|---|---|---|
| LineageOS 18.1 (Android 11) | stock Android 11 | installs and boots |

---

## What the script does

1. Detects whether the partition images already exist, or have to be extracted
   from the ROM package.
2. Builds a `vbmeta` image signed with your RSA-2048 key, with
   `flags=3` (verification disabled) and `rollback_index=0`.
3. Flashes the physical partitions in the bootloader:
   `vbmeta`, `vbmeta_system`, `boot`, `dtbo`, `vendor_boot`.
4. Wipes `metadata` and formats `userdata` in the bootloader (optional).
5. Boots into **fastbootd** and flashes the logical partitions inside `super`:
   `system`, `system_ext`, `vendor`, `product`, `odm`. This keeps the existing
   `super` layout (groups and metadata) intact.
6. Reboots.

No `dd` is ever used. Nothing is written outside the listed partitions, and
`avb_custom_key` is never written.

---

## Requirements

Host:

| Tool | Purpose |
|---|---|
| `fastboot` (Android platform-tools, >= 33) | flashing |
| `avbtool` (AOSP `external/avb`) | signing `vbmeta` |
| `openssl` | generating the AVB key pair (`--gen-keys`) |
| `python3` + `unzip` | reading/extracting the ROM package |
| `payload_dumper` | extracting images from `payload.bin` |

`payload_dumper` is installed into a local virtualenv by the setup script.

Install the Python dependency:

```bash
./tools/setup-deps.sh
```

This creates `.venv/` in the repository and checks the host tools.

---

## Quick start

```bash
# 1. install Python dependencies (once)
./tools/setup-deps.sh

# 2. put the ROM package in this directory (or use --zip)
cp /path/to/rom.zip .

# 3. create the AVB key pair (once; generates keys and exits)
./flash-rom.sh --gen-keys

# 4. see what the script would do
./flash-rom.sh --detect
./flash-rom.sh --dry-run

# 5. install
./flash-rom.sh
```

The device must be in **bootloader/fastboot mode**, not in Android and not in
fastbootd.

---

## Options

| Option | Description |
|---|---|
| `--dry-run`, `-n` | print every command, change nothing |
| `--detect` | report the state (images vs payload) and exit |
| `--zip FILE` | ROM package (default: first `*.zip` in the working directory) |
| `--images DIR`, `--images-dir DIR` | where images live / are extracted (default: script directory) |
| `--keys DIR` | AVB key directory (default: `keys/` next to the script) |
| `--logical "system vendor product"` | override the logical partition list |
| `--super-image FILE` | flash an existing `super` image instead of using fastbootd |
| `--no-extract` | never extract; fail if images are missing |
| `--no-wipe` | keep `userdata` and `metadata` |
| `--gen-keys` | create the AVB key pair if it is missing, then exit |
| `--register-key` | write the public key to `avb_custom_key` and exit (no ROM flashing) |
| `--serial SERIAL` | select a specific device |
| `--help`, `-h` | usage |

---

## How `vbmeta` signing works

The generated `vbmeta` contains:

- your public key (RSA-2048, `SHA256_RSA2048`),
- `flags = 3` — verification and hashtree checks disabled,
- `rollback_index = 0` — no anti-rollback side effects,
- the descriptors copied from the ROM's own `vbmeta` (chain + hash entries),
  which are ignored at runtime because verification is disabled.

The bootloader still verifies the `vbmeta` signature against a trusted key
before it looks at the flags. The key is used only for signing; the script never
writes it to `avb_custom_key`.

---

## Wipe behaviour

By default the script runs, in the bootloader:

```bash
fastboot erase metadata
fastboot format userdata
```

`fastboot -w` is not used because fastbootd on this platform reports
`wipe task partition not found` for `userdata`, `cache` and `metadata`.

Use `--no-wipe` to keep the existing data (usually not recommended when
switching ROMs).

---

## Restoring stock firmware

Flash the official firmware package for your model with `fastboot` — it
contains a complete, self-consistent set of images and is the authoritative
recovery path. The script only touches the partitions listed above; it never
writes bootloader, modem, TZ, `devinfo`, `misc` or `avb_custom_key`.

---

## Security notes

- **Never commit private keys.** `.gitignore` excludes `keys/`.
- The private key (`keys/avb_test_private.pem`) must stay on your machine and
  be backed up: losing it means you can no longer sign images that the device
  trusts.
- The public key (`keys/avb_test_public.bin`) is not secret.
- The registered key is a boot trust anchor. Treat the private key with the
  same care as a signing key for the device.
- Using `flags=3` disables verified boot for the flashed system. That is a
  deliberate choice for custom ROMs and lowers the security guarantees of the
  device.

---

## Limitations

- Device specific: ASUS Zenfone 8 (`ASUS_I006D`), A/B with dynamic partitions.
- The ROM must match the installed firmware's Android/vendor level; newer
  Android releases need newer vendor firmware, which this tool does not flash.
- The device must already trust your AVB key through `avb_custom_key`
  (otherwise an unlocked bootloader is required).
- ROM packages must be A/B OTA packages with `payload.bin`, or ZIPs that
  contain plain `.img` files.
- Large images are sent in chunks by `fastboot`; the message
  `Invalid sparse file format at header magic` is harmless and expected.

---

## License

MIT — see [LICENSE](LICENSE).
