# Bug Report & Remediation Guide: Acer Swift Go 16 AI (`SFG16-I71T`) — `VIDEO_MEMORY_MANAGEMENT_INTERNAL` (`0x0000010E`) BSOD

* **Date Audited:** November 3, 2026 (`2026-11-03`)
* **System Manufacturer & Model:** `Acer` `Swift SFG16-I71T` (Acer Swift Go 16 AI)
* **System BIOS:** `V1.05` (`04/07/2026`) — *Pending WHQL Update: `Insyde Software Firmware Driver Update (1.0.6.0)`*
* **Bug Check String:** `VIDEO_MEMORY_MANAGEMENT_INTERNAL`
* **Stop Code:** `0x0000010E` (`0x10E`)
* **Faulting Kernel Subsystem:** `dxgmms2.sys` (DirectX Graphics MMS2) / Intel NPU WDDM Compute Accelerator (`oem72.inf`)
* **Upstream Reference:** [Acer Community Discussion #741856: Swift Go 16 AI Crashing — The Error Is VIDEO\_MEMORY\_MANAGEMENT\_INTERNAL (0x10e)](https://community.acer.com/en/discussion/741856/swift-go-16-ai-crashing-the-error-is-video-memory-management-internal-0x10e)
* **Automated Remediation Script:** [`scripts/fix_acer_0x10e_bsod.ps1`](../scripts/fix_acer_0x10e_bsod.ps1)

---

## 1. Local System Audit (`Swift SFG16-I71T`)

An automated inspection of the local Windows Driver Store, PCI Hardware IDs, Power Manager Registry, and `C:\Windows\Minidump` confirmed that this machine is directly affected by the issue reported in [Acer Community Discussion #741856](https://community.acer.com/en/discussion/741856/swift-go-16-ai-crashing-the-error-is-video-memory-management-internal-0x10e):

| Subsystem / Parameter | Audited Pre-Fix Value (`2026-11-03`) | Post-Fix Verified Value (`2026-11-03`) | Status |
| :--- | :--- | :--- | :--- |
| **System Model** | `Acer Swift SFG16-I71T` (BIOS `V1.05`, `04/07/2026`) | BIOS `V1.06` (`1.0.6.0` WHQL Firmware Staged) | **RESOLVED (Pending Reboot)** |
| **Intel(R) NPU Driver** | **`32.0.100.4509`** (`11-19-2025`, `oem72.inf`, `PCI\VEN_8086&DEV_B03E`) | **`32.0.100.4841`** (`7-24-2026`, `oem160.inf`) | **FIXED (`> 32.0.100.4512`)** |
| **Intel(R) Graphics Driver** | `32.0.101.8356` (`11-20-2025`, `oem16.inf`, `PCI\VEN_8086&DEV_B090&SUBSYS_20421025`) | **`32.0.101.8724`** (`4-16-2026`, `oem161.inf`) | **UPDATED** |
| **Windows Fast Startup** | `HiberbootEnabled = 1` (Enabled) | **`HiberbootEnabled = 0`** (Disabled) | **FIXED** |
| **WDDM TDR Recovery Delay** | `TdrDelay` / `TdrDdiDelay` unset (2s default) | **`TdrDelay = 10`, `TdrDdiDelay = 10`** (10s grace) | **FIXED** |
| **Recent Crash Minidumps** | `110326-14953-01.dmp` (`11/3/2026 6:30:58 PM`)<br>`110326-13250-01.dmp` (`11/3/2026 6:40:17 PM`) | Zero `0x10E` bugchecks after remediation | **2 crashes recorded pre-fix** |

---

## 2. Root Cause Analysis

1. **Unified WDDM Memory Management on Intel Core Ultra Platforms:**
   On the **Acer Swift Go 16 AI (`SFG16-I71T`)**, both the integrated **Intel(R) Graphics (`PCI\VEN_8086&DEV_B090`)** and the **Intel(R) AI Boost Neural Processing Unit (`Intel(R) NPU`, `PCI\VEN_8086&DEV_B03E`)** operate as WDDM devices that allocate and share unified LPDDR5X system memory pages through the Windows DirectX Graphics Memory Manager (`dxgmms2.sys`).
2. **Defect in Intel NPU Driver Branch `32.0.100.4509` / `32.0.100.4512`:**
   As confirmed in [Acer Community Discussion #741856](https://community.acer.com/en/discussion/741856/swift-go-16-ai-crashing-the-error-is-video-memory-management-internal-0x10e), early factory and Windows Update Intel NPU driver builds (`32.0.100.4509` and `32.0.100.4512`) contain a shared-memory page-tracking and power-state transition defect. When Windows background AI workloads (Windows Studio Effects, Recall/Click-to-Do, background NPU telemetry, or browser/IDE GPU+NPU hardware acceleration) transition power states or release shared WDDM allocations, `dxgmms2.sys` detects an invalid video/compute memory reference and halts the kernel with **`VIDEO_MEMORY_MANAGEMENT_INTERNAL` (`0x0000010E`)**.
3. **Warning About Pending Windows Update `32.0.100.4512` Extension:**
   Scanning the Windows Update Agent (`Microsoft.Update.Session`) revealed that Windows Update has **both** `Intel Corporation Extension Driver Update (32.0.100.4512)` (which is still affected by the `0x10E` bug) **and** the newer patched **`Intel Corporation ComputeAccelerator Driver Update (32.0.100.4841)`** in the optional driver queue. Our automated script [`scripts/fix_acer_0x10e_bsod.ps1`](../scripts/fix_acer_0x10e_bsod.ps1) explicitly filters out `32.0.100.4512` and selects **`32.0.100.4841`** along with **`Intel Corporation Display Driver Update (32.0.101.8724)`** and **`Insyde Software Firmware Driver Update (1.0.6.0)`**.
4. **Fast Startup (`HiberbootEnabled = 1`) Persistence:**
   With Windows Fast Startup enabled (`HiberbootEnabled = 1`), kernel session hibernation saves stale WDDM/NPU device contexts to `hiberfil.sys` on shutdown and reloads them on boot, causing recurring `0x10E` crashes shortly after wake or startup.

---

## 3. Automated Remediation (`scripts/fix_acer_0x10e_bsod.ps1`)

We created [`scripts/fix_acer_0x10e_bsod.ps1`](../scripts/fix_acer_0x10e_bsod.ps1) to automate the entire remediation workflow.

### What `scripts/fix_acer_0x10e_bsod.ps1` Does
1. **Audits Installed NPU & Graphics Drivers:** Reads `HKLM:\SYSTEM\CurrentControlSet\Control\Class` to verify the active `Intel(R) NPU` (`PCI\VEN_8086&DEV_B03E`) and `Intel(R) Graphics` (`PCI\VEN_8086&DEV_B090`) driver versions.
2. **Selects & Installs Patched WHQL Drivers via Windows Update Agent (`Microsoft.Update.Session`):**
   - `Intel Corporation ComputeAccelerator Driver Update (32.0.100.4841)` *(fixes the `0x10E` NPU WDDM crash)*
   - `Intel Corporation Extension Driver Update (32.0.100.4841)`
   - `Intel Corporation Display Driver Update (32.0.101.8724)` *(updates integrated Intel Graphics from `32.0.101.8356`)*
   - `Intel Corporation Extension Driver Update (32.0.101.8724)`
   - `Insyde Software Firmware Driver Update (1.0.6.0)` *(updates system BIOS from `V1.05` to `V1.06`)*
   - Explicitly **skips** the buggy `32.0.100.4512` extension update.
3. **Installs Standalone Intel NPU Driver (`32.0.100.5540`) if Downloaded:**
   If you download the latest upstream Intel installer (`npu_win_32.0.100.5540.exe`, SHA-256: `FBA32699B699918A793FCA05CFC6C607C8745772057347476ECD8C4CF7746048`) from [Intel® NPU Driver — Windows* (ID 794734)](https://www.intel.com/content/www/us/en/download/794734/intel-npu-driver-windows.html) into your `Downloads` folder, the script automatically detects and installs it silently (`--quiet --norestart`).
4. **Disables Windows Fast Startup (`HiberbootEnabled = 0` & `powercfg /h off`):**
   Ensures every boot performs a clean WDDM + NPU hardware initialization.
5. **Configures WDDM Timeout Detection & Recovery (`TdrDelay = 10`, `TdrDdiDelay = 10`):**
   Configures `HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers` so transient NPU/GPU compute stalls gracefully reset the user-mode driver rather than triggering a `0x10E` kernel panic.

### How to Execute the Privileged Fix (1 Command in Admin Terminal)

Because the IDE terminal runs inside a Windows Job Object container that blocks child UAC elevation (`Start-Process -Verb RunAs` returns `ERROR_NOT_SUPPORTED`), run [`scripts/fix_acer_0x10e_bsod.ps1`](../scripts/fix_acer_0x10e_bsod.ps1) directly in an elevated **Terminal (Admin)** window:

1. Press **`Win + X`** and select **Terminal (Admin)** (or **PowerShell (Admin)**).
2. Run:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\kkpra\plans\scripts\fix_acer_0x10e_bsod.ps1"
   ```
3. Restart your laptop once the script completes.

---

## 4. Alternative Manual Remediation Steps

If you prefer to apply or verify each step manually:

### Step A: Update the Intel NPU Driver to `32.0.100.4841` (WHQL) or `32.0.100.5540` (Intel Direct)
* **Option 1 (Windows Update Optional Drivers):**
  Open **Settings -> Windows Update -> Advanced options -> Optional updates -> Driver updates**, check:
  - `Intel Corporation - ComputeAccelerator - 32.0.100.4841`
  - `Intel Corporation - Display - 32.0.101.8724`
  - `Insyde Software - Firmware - 1.0.6.0`
  *(Do **not** select `32.0.100.4512`.)*
* **Option 2 (Intel Direct Installer `32.0.100.5540`):**
  Download and run `npu_win_32.0.100.5540.exe` directly from [Intel® NPU Driver — Windows* (Download ID 794734)](https://www.intel.com/content/www/us/en/download/794734/intel-npu-driver-windows.html).

### Step B: Disable Windows Fast Startup & Configure WDDM TDR Resilience (Admin PowerShell)
```powershell
# Disable Windows Fast Startup
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -Force
powercfg.exe /h off

# Set WDDM TDR recovery delay to 10 seconds
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "TdrDelay" -Value 10 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "TdrDdiDelay" -Value 10 -Type DWord -Force
```

### Step C: Post-Reboot Verification
After rebooting, run [`scripts/fix_acer_0x10e_bsod.ps1`](../scripts/fix_acer_0x10e_bsod.ps1) (or check **Device Manager -> Neural processors -> Intel(R) NPU -> Properties -> Driver**) to confirm:
- **Driver Version:** `32.0.100.4841` or `32.0.100.5540` (no longer `32.0.100.4509`)
- **`HiberbootEnabled`:** `0`
- **`TdrDelay` / `TdrDdiDelay`:** `10`
