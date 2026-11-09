// generate_commercial_audio.js
// Synthesizes commercial-ready voiceover narration for Little Wallet (PayPal AI Hackathon)
// Using Google Gemini 3.8 Flash TTS (Zephyr voice) + FFmpeg mastering

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

const API_KEY = process.env.GEMINI_API_KEY || "";
const ROOT = "/Users/jiawenzhu/Developer/Little Wallet/commercial-video";
const STEMS_DIR = path.join(ROOT, "stems");
const AUDIO_DIR = path.join(ROOT, "audio");
const BGM_PATH = "/Users/jiawenzhu/Developer/restage-design/hackathon-video/bgm.mp3";

fs.mkdirSync(STEMS_DIR, { recursive: true });
fs.mkdirSync(AUDIO_DIR, { recursive: true });

export const COMMERCIAL_BEATS = [
  {
    id: "01_hook",
    title: "The Everyday Problem",
    style: "conversational, empathetic, relatable, warm opening",
    text: "Splitting dinner, chasing down group grocery bills, or tracking shared expenses shouldn't feel like a second job. We juggle screenshots, do napkin math, and send awkward payment reminders. But what happens when you put AI behind the wheel of PayPal?"
  },
  {
    id: "02_intro",
    title: "Introducing Little Wallet",
    style: "bright, upbeat, proud, modern tech copilot",
    text: "Meet Little Wallet. It's a fresh, tactile personal finance companion designed for how people actually spend and share money in real life."
  },
  {
    id: "03_voice_ai",
    title: "Voice AI - Say It",
    style: "energetic, crisp, articulate, conversational",
    text: "Just tap 'Say it'. Say: 'Trader Joe's, eighty-four dollars, split three ways with Sam and Alex.' On-device intelligence instantly understands the shop, itemizes the purchase, calculates exact tax and tip, and splits the total down to the cent."
  },
  {
    id: "04_vision_receipt",
    title: "Vision AI - Scan Receipt",
    style: "smooth, engaging, clear and polished",
    text: "Got a paper receipt? Snap a photo. Our Vision AI extracts every single line item and lets you assign items to friends with a tap, keeping your monthly budget organized effortlessly."
  },
  {
    id: "05_settle_up",
    title: "Instant PayPal & Venmo Settle-Up",
    style: "confident, seamless, enthusiastic product showcase",
    text: "Settling up is completely frictionless. Little Wallet generates instant settle-up links. Your friends don't even need the app installed. They tap their link, pay securely with PayPal or Venmo, and the money goes straight to your account."
  },
  {
    id: "06_live_webhooks",
    title: "Live Webhooks & Instant Verification",
    style: "crisp, sharp, impressed by real-time speed",
    text: "And thanks to PayPal's real-time webhooks, the exact second a friend completes payment, their status flips from 'Waiting' to 'Paid' live on your screen. No manual checks. No guessing."
  },
  {
    id: "07_penny_agent",
    title: "Penny AI Financial Agent",
    style: "smart, capable, proactive, authoritative AI assistant",
    text: "Then there's Penny, your autonomous financial copilot. If a friend forgets to pay, Penny drafts an official PayPal Invoice. Overcharged someone? Penny prepares an instant PayPal Refund. Reimbursing multiple roommates? Penny executes a batch PayPal Payout in one tap. Every action is laid out clearly, and nothing moves without your confirmation."
  },
  {
    id: "08_outro_cta",
    title: "Closing & Hackathon Vision",
    style: "inspiring, punchy, triumphant, memorable sign-off",
    text: "From spoken words to completed transactions. No awkward texts. No spreadsheets. Just intelligent, effortless payments. Little Wallet: Build what's next with PayPal and AI."
  }
];

function findAudio(obj) {
  if (!obj) return null;
  if (typeof obj === "object") {
    for (const [k, v] of Object.entries(obj)) {
      if ((k === "data" || k === "audio_content" || k === "audioContent") && typeof v === "string" && v.length > 200) {
        return v;
      }
      const res = findAudio(v);
      if (res) return res;
    }
  } else if (Array.isArray(obj)) {
    for (const item of obj) {
      const res = findAudio(item);
      if (res) return res;
    }
  }
  return null;
}

async function synthesizeClip(beat, retries = 5) {
  const payload = {
    model: "gemini-3.8-flash-tts",
    input: [{
      type: "user_input",
      content: [{
        type: "text",
        text: beat.text,
        annotations: [{ type: "speech_metadata", style: beat.style }]
      }]
    }],
    response_format: { type: "audio" },
    generation_config: { speech_config: [{ voice: "Zephyr" }] }
  };

  const url = `https://generativelanguage.googleapis.com/v1beta/interactions?key=${API_KEY}`;
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      });
      if (res.status === 429) {
        console.warn(`  ⏳ [429 Rate Limit] Pacing required. Waiting 25s before retry (attempt ${attempt}/${retries})...`);
        await new Promise(r => setTimeout(r, 25000));
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status} ${await res.text()}`);
      const json = await res.json();
      const b64 = findAudio(json);
      if (!b64) throw new Error("Audio content missing from response");
      return Buffer.from(b64, "base64");
    } catch (err) {
      console.warn(`  [Retry ${attempt}/${retries}] Beat ${beat.id}: ${err.message}`);
      if (attempt === retries) throw err;
      await new Promise(r => setTimeout(r, 5000));
    }
  }
}

async function main() {
  console.log("🎙️  Synthesizing Commercial Narration with Gemini 3.8 Flash TTS (Zephyr)...");
  const stemFiles = [];

  for (let i = 0; i < COMMERCIAL_BEATS.length; i++) {
    const beat = COMMERCIAL_BEATS[i];
    const stemPath = path.join(STEMS_DIR, `${String(i + 1).padStart(2, "0")}_${beat.id}.wav`);
    console.log(`\n▶️  [Beat ${i + 1}/${COMMERCIAL_BEATS.length}] ${beat.title} (${beat.id})`);
    
    if (fs.existsSync(stemPath) && fs.statSync(stemPath).size > 1000) {
      const dur = execSync(`ffprobe -i "${stemPath}" -show_entries format=duration -v quiet -of csv="p=0"`).toString().trim();
      console.log(`   ⚡ Stem already exists! Reusing: ${parseFloat(dur).toFixed(1)}s`);
      stemFiles.push(stemPath);
      continue;
    }

    console.log(`   "${beat.text.slice(0, 60)}..."`);
    const audioBuf = await synthesizeClip(beat);
    fs.writeFileSync(stemPath, audioBuf);
    stemFiles.push(stemPath);

    const dur = execSync(`ffprobe -i "${stemPath}" -show_entries format=duration -v quiet -of csv="p=0"`).toString().trim();
    console.log(`   ✅ Generated ${parseFloat(dur).toFixed(1)}s (${(audioBuf.length / 1024).toFixed(1)} KB)`);

    // Pacing to stay strictly under 3 requests / minute
    if (i < COMMERCIAL_BEATS.length - 1) {
      console.log("   ⏳ Pacing 21s before next request...");
      await new Promise(r => setTimeout(r, 21000));
    }
  }

  // Generate 0.45s silence for natural breathing between beats
  const silencePath = path.join(STEMS_DIR, "silence.wav");
  execSync(`ffmpeg -y -v error -f lavfi -i anullsrc=r=24000:cl=mono -t 0.45 "${silencePath}"`);

  // Build ffmpeg concat list
  const concatListPath = path.join(STEMS_DIR, "concat.txt");
  let concatContent = "";
  for (let i = 0; i < stemFiles.length; i++) {
    concatContent += `file '${stemFiles[i]}'\n`;
    if (i < stemFiles.length - 1) {
      concatContent += `file '${silencePath}'\n`;
    }
  }
  fs.writeFileSync(concatListPath, concatContent);

  // Concatenate master narration
  const masterWav = path.join(AUDIO_DIR, "little_wallet_commercial_narration.wav");
  const masterMp3 = path.join(AUDIO_DIR, "little_wallet_commercial_narration.mp3");

  console.log("\n🎛️  Concatenating Master Voiceover Track...");
  execSync(`ffmpeg -y -v error -f concat -safe 0 -i "${concatListPath}" -c:a pcm_s16le "${masterWav}"`);
  execSync(`ffmpeg -y -v error -i "${masterWav}" -b:a 192k "${masterMp3}"`);

  const totalDur = execSync(`ffprobe -i "${masterWav}" -show_entries format=duration -v quiet -of csv="p=0"`).toString().trim();
  console.log(`   ✅ Pure Voiceover Master: ${parseFloat(totalDur).toFixed(1)}s -> ${masterMp3}`);

  // Create Broadcast Commercial Mix (Voiceover + Soft BGM)
  const masterMixMp3 = path.join(AUDIO_DIR, "little_wallet_commercial_master_with_bgm.mp3");
  if (fs.existsSync(BGM_PATH)) {
    console.log("\n🎵 Mixing Broadcast Master with Ambient BGM...");
    const durSec = parseFloat(totalDur);
    // BGM loop & volume ducked to 0.04 (-28dB), fade-in 1.5s, fade-out 3s at end
    const filter = `[1:a]volume=0.038,afade=t=in:st=0:d=1.5,afade=t=out:st=${Math.max(0, durSec - 3)}:d=3[bgm];[0:a][bgm]amix=inputs=2:duration=first:dropout_transition=2[out]`;
    execSync(`ffmpeg -y -v error -i "${masterWav}" -stream_loop -1 -i "${BGM_PATH}" -filter_complex "${filter}" -map "[out]" -b:a 192k "${masterMixMp3}"`);
    console.log(`   ✅ Broadcast Master with BGM: -> ${masterMixMp3}`);
  }

  console.log("\n🎉 All Audio Production Complete!");
}

main().catch(err => {
  console.error("FATAL ERROR:", err);
  process.exit(1);
});
