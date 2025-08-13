#!/usr/bin/env bash
set -euo pipefail

# ========== إدخال يدوي مطلوب ========== 
# ضع توكن بوت تيليجرام هنا أو مرّره من Colab قبل التشغيل: export TELEGRAM_BOT_TOKEN="123456:ABC..."
: "${TELEGRAM_BOT_TOKEN:?Please export TELEGRAM_BOT_TOKEN before running}"

# ========== مسارات التخزين ==========
export N8N_USER_FOLDER="/content/drive/MyDrive/n8n"   # تخزين دائم في Google Drive
mkdir -p "$N8N_USER_FOLDER"

# ========== Node & n8n ==========
if ! command -v node >/dev/null 2>&1; then
  echo "Installing Node.js 18..."
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

echo "Installing n8n CLI..."
sudo npm i -g n8n@latest

# ========== cloudflared ==========
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "Installing cloudflared..."
  sudo apt-get update
  sudo apt-get install -y wget
  wget -qO cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x cloudflared
  sudo mv cloudflared /usr/local/bin/
fi

# ========== تهيئة n8n ==========
export N8N_PORT=5678
export N8N_PROTOCOL=http
export N8N_HOST=localhost
# Webhook عام سيملأ لاحقًا بعد معرفة رابط النفق
export WEBHOOK_URL=""
# URL واجهة التحرير (ليس ضروريًا علنًا)
export N8N_EDITOR_BASE_URL="http://localhost:${N8N_PORT}"

# مفاتيح الأمان والتشفير
if [ ! -f "${N8N_USER_FOLDER}/.encryption_key" ]; then
  openssl rand -hex 24 > "${N8N_USER_FOLDER}/.encryption_key"
fi
export N8N_ENCRYPTION_KEY="$(cat "${N8N_USER_FOLDER}/.encryption_key")"

# تمرير متغير توكن تيليجرام ليقرأه الاستيراد (ENV:TELEGRAM_BOT_TOKEN)
export TELEGRAM_BOT_TOKEN

# ========== تشغيل n8n بالخلفية ==========
echo "Starting n8n..."
# نضمن استخدام مجلد المستخدم المخصص
export N8N_USER_FOLDER
# تشغيل n8n في الخلفية
nohup n8n start > "${N8N_USER_FOLDER}/n8n.log" 2>&1 &

# انتظار منفذ 5678
echo "Waiting for n8n to listen on port ${N8N_PORT}..."
for i in {1..60}; do
  if nc -z localhost ${N8N_PORT}; then
    break
  fi
  sleep 1
done

# ========== تشغيل نفق cloudflared ==========
echo "Starting Cloudflare tunnel..."
nohup cloudflared tunnel --url "http://localhost:${N8N_PORT}" --logfile "${N8N_USER_FOLDER}/cloudflared.log" > /dev/null 2>&1 &

# استخراج رابط trycloudflare.com
echo "Fetching public URL..."
PUBLIC_URL=""
for i in {1..60}; do
  PUBLIC_URL=$(grep -oE "https://[a-z0-9.-]+trycloudflare.com" "${N8N_USER_FOLDER}/cloudflared.log" | tail -n1 || true)
  if [ -n "$PUBLIC_URL" ]; then
    break
  fi
  sleep 1
done
if [ -z "$PUBLIC_URL" ]; then
  echo "Failed to obtain public URL from cloudflared logs."
  exit 1
fi
echo "Public URL: $PUBLIC_URL"

# تحديث WEBHOOK_URL وإعادة تشغيل n8n ليأخذ الإعداد
export WEBHOOK_URL="$PUBLIC_URL"
echo "Restarting n8n with WEBHOOK_URL..."
pkill -f "n8n start" || true
sleep 2
nohup env WEBHOOK_URL="$WEBHOOK_URL" n8n start > "${N8N_USER_FOLDER}/n8n.log" 2>&1 &

# انتظار إعادة التشغيل
sleep 5

# ========== استيراد Credentials & Workflow ==========
# NOTE: أوامر الاستيراد تستخدم نفس N8N_USER_FOLDER لضمان التوافق
echo "Importing Telegram credentials..."
n8n import:credentials --input "./credentials/telegram_api.json" || true

echo "Importing Telegram Echo workflow (active)..."
n8n import:workflow --input "./workflows/telegram_echo.json"

echo "All set!"
echo "Editor (local): http://localhost:${N8N_PORT}"
echo "Public (for webhooks): ${PUBLIC_URL}"
