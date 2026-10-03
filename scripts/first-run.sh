#!/bin/bash
# ============================================================================
#  Rosetta Stone — สคริปต์แก้ปัญหา Gatekeeper ในการเปิดครั้งแรก
#  Rosetta Stone — first-run Gatekeeper override
# ============================================================================
#
#  ข้อเท็จจริงที่ต้องพูดตรงๆ (honest engineering)
#  ---------------------------------------------------------------
#  Rosetta Stone ถูกเซ็นแบบ ad-hoc (CODE_SIGN_IDENTITY = "-") ไม่มี Developer ID
#  และ **ไม่เคยผ่านการ notarize** แม้แต่ครั้งเดียว
#
#  การเซ็นแบบ ad-hoc **ไม่สามารถข้าม Gatekeeper ได้เอง** ต้องพึ่งผู้ใช้อนุมัติ
#  อย่างน้อยหนึ่งครั้ง ทางเลือกมีสองแบบ:
#
#    1) คลิกขวาที่ไอคอนแอป -> เลือก "Open" -> เลือก "Open" อีกครั้ง
#       (ครั้งเดียวต่อไฟล์ที่ดาวน์โหลดมา เพราะ macOS จำ quarantine ไว้)
#
#    2) รันสคริปต์นี้ เพื่อถอด quarantine attribute ออกทั้งแอป
#       (ทำครั้งเดียว แล้วทุกครั้งต่อไปจะไม่ถามอีก)
#
#  สคริปต์นี้ **ไม่ได้** ปิด Gatekeeper และ **ไม่ได้** ทำให้แอปปลอดภัยขึ้น
#  มันแค่บอก macOS ว่า "ผู้ใช้อนุมัติไฟล์ชุดนี้แล้ว" เท่านั้น
# ============================================================================

set -euo pipefail

# ชื่อ bundle ทางการ — เป็นชื่อเดียวกันทุกสถาปัตยกรรมตั้งแต่ Phase 8
# ตัวแอปเขียนชื่อ .app ว่า RosettaStone.app เสมอ ไม่มี suffix -Intel / -AppleSilicon
# เพราะสิ่งที่ผู้ใช้เห็นใน /Applications ต้องไม่ผูกกับชิปของเครื่อง
TARGET_APP="/Applications/RosettaStone.app"

# ชื่อที่ผู้ใช้อาจเห็นใน Finder (ถ้าเคย rename เอง) — รองรับไว้ แต่ไม่ใช่ชื่อทางการ
FALLBACK_APP="/Applications/Rosetta Stone.app"

# ชื่อจาก Phase ก่อนหน้า — ตรวจพบแล้วเตือนให้ลบ แต่ไม่ลบให้เอง
LEGACY_APPS=(
  "/Applications/RosettaStone-Intel.app"
  "/Applications/RosettaStone-AppleSilicon.app"
)

echo "=============================================="
echo " Rosetta Stone — แก้ปัญหา Gatekeeper / Gatekeeper fix"
echo "=============================================="
echo

# เลือกแอปที่มีอยู่จริง — ชื่อทางการก่อนเสมอ
TARGET=""
for candidate in "$TARGET_APP" "$FALLBACK_APP"; do
  if [ -d "$candidate" ]; then
    TARGET="$candidate"
    break
  fi
done

# ถ้าไม่เจอใน /Applications ให้ลองหาจากตำแหน่งอื่นที่พบบ่อย
if [ -z "$TARGET" ]; then
  for candidate in "$HOME/Applications/RosettaStone.app" "$HOME/Applications/Rosetta Stone.app"; do
    if [ -d "$candidate" ]; then
      TARGET="$candidate"
      break
    fi
  done
fi

# เตือนเรื่อง bundle รุ่นเก่าที่ยังอยู่ใน /Applications
# ไม่ลบให้เอง เพราะการลบแอปใน /Applications เป็นการลบไฟล์ให้ผู้ใช้
LEGACY_FOUND=()
for legacy in "${LEGACY_APPS[@]}"; do
  if [ -d "$legacy" ]; then
    LEGACY_FOUND+=("$legacy")
  fi
done

if [ ${#LEGACY_FOUND[@]} -gt 0 ]; then
  echo "=============================================="
  echo " พบแอปรุ่นเก่าที่ยังอยู่ใน /Applications"
  echo " Legacy app bundles still present in /Applications"
  echo "=============================================="
  for legacy in "${LEGACY_FOUND[@]}"; do
    echo "  - $legacy"
  done
  echo
  echo "แอปรุ่นใหม่ใช้ชื่อ $TARGET_APP เสมอ ไม่ว่าเครื่องจะเป็น Intel หรือ Apple Silicon"
  echo "แนะนำให้ลบแอปรุ่นเก่าทิ้งเอง เพื่อไม่ให้มีสองตัวชนกันใน /Applications:"
  echo "  ลากทิ้งใน Finder / หรือรันคำสั่งนี้:"
  echo "  sudo rm -rf \"/Applications/RosettaStone-Intel.app\" \"/Applications/RosettaStone-AppleSilicon.app\""
  echo
  echo "(The script does not delete them for you — removing apps must stay your decision.)"
  echo
fi

if [ -z "$TARGET" ]; then
  echo "ไม่พบ Rosetta Stone ใน /Applications"
  echo "Rosetta Stone not found in /Applications"
  echo
  echo "วิธีแก้ / Fix:"
  echo "  1. ลากแอปจาก DMG ไปวางใน Applications ก่อน (Drag the app from the DMG to Applications)"
  echo "  2. แล้วรันสคริปต์นี้อีกครั้ง (then run this script again)"
  echo
  echo "ถ้าติดตั้งไว้ที่โฟลเดอร์อื่น ให้ส่งพาธมาเอง:"
  echo "  bash first-run.sh \"/path/to/RosettaStone.app\""
  exit 1
fi

echo "พบแอป / Found app: $TARGET"
echo

# ตรวจสอบสถานะ quarantine ก่อน เพื่อบอกผู้ใช้ว่าจำเป็นต้องทำอะไรหรือไม่
if xattr -p com.apple.quarantine "$TARGET" >/dev/null 2>&1; then
  echo "พบ quarantine attribute — กำลังถอดออก"
  echo "Quarantine attribute found — removing it now"
else
  echo "ไม่พบ quarantine attribute — อาจเปิดผ่านมาแล้ว หรือเคยถอดไปแล้ว"
  echo "No quarantine attribute found — nothing to remove (already cleared)"
  echo
fi

# คำสั่งหลัก: ถอด quarantine แบบ recursive (-r) ทั้งแอป
# -d = delete attribute, -r = recursive ลงไปทุกไฟล์ข้างใน bundle
xattr -dr com.apple.quarantine "$TARGET"

echo
echo "เรียบร้อย / Done."
echo
echo "ขั้นตอนถัดไป / Next:"
echo "  1. เปิดแอปจาก Applications ได้เลย (Open it from Applications)"
echo "  2. แอปจะเปิดเป็นหน้าต่างปกติ (โหมดเริ่มต้น) — ยังไม่มีไอคอนที่เมนูบาร์"
echo "     (it opens as a normal window — the default mode; no menu-bar icon yet)"
echo "  3. ถ้าต้องการโหมดเมนูบาร์: เปิดสวิตช์ Run at Startup ในแผง"
echo "     (for menu-bar mode, turn on Run at Startup: the glyph appears in the menu bar,"
echo "      left-click toggles Gatekeeper, right-click opens the menu)"
echo
echo "หมายเหตุ / Note:"
echo "  สคริปต์นี้ไม่ได้ปิด Gatekeeper — แอปยังถูกตรวจสอบตามปกติ"
echo "  This script does NOT disable Gatekeeper; the app is still assessed normally."
