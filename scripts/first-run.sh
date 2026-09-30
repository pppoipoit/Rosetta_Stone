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

# ตำแหน่งแอป 2 แบบ: ชื่อที่ build จริงใช้ (RosettaStone.app ไม่มีเว้นวรรค)
# และชื่อที่ผู้ใช้อาจเห็นใน Finder (Rosetta Stone.app)
APP_CANDIDATES=(
  "/Applications/RosettaStone.app"
  "/Applications/Rosetta Stone.app"
)

echo "=============================================="
echo " Rosetta Stone — แก้ปัญหา Gatekeeper / Gatekeeper fix"
echo "=============================================="
echo

# เลือกแอปที่มีอยู่จริง
TARGET=""
for candidate in "${APP_CANDIDATES[@]}"; do
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
echo "  2. เครื่องครั้งแรกจะเปิดหน้าต่างแผงหลักให้เห็นหนึ่งครั้ง"
echo "     (first launch shows the panel once — so it never looks like a dead app)"
echo "  3. ไอคอนจะปรากฏที่เมนูบาร์ด้านบน ไม่มีไอคอนใน Dock"
echo "     (the glyph appears in the menu bar; there is no Dock icon)"
echo
echo "หมายเหตุ / Note:"
echo "  สคริปต์นี้ไม่ได้ปิด Gatekeeper — แอปยังถูกตรวจสอบตามปกติ"
echo "  This script does NOT disable Gatekeeper; the app is still assessed normally."
