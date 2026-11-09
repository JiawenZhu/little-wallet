#!/usr/bin/env python3
"""Synthesize a delightful, human-voice commercial for Little Wallet (PayPal AI Hackathon).

Matches the exact storytelling tone, Autonoe voice (Gemini 3.8 Flash TTS),
and synthesized musical groove from 3D Craft (https://www.youtube.com/watch?v=f1fNLKiQ-MI).
"""

import os
import json
import base64
import urllib.request
import subprocess
import time
import wave
import numpy as np

API_KEY = os.environ.get("GEMINI_API_KEY", "")
ROOT_DIR = "/Users/jiawenzhu/Developer/Little Wallet/commercial-video"
STEMS_DIR = os.path.join(ROOT_DIR, "autonoe_stems")
AUDIO_DIR = os.path.join(ROOT_DIR, "audio")
os.makedirs(STEMS_DIR, exist_ok=True)
os.makedirs(AUDIO_DIR, exist_ok=True)

SR = 48000
DUR = 108.0
N = int(SR * DUR)
rng = np.random.default_rng(42)

# Story beats in the 3D Craft human storytelling style
STORY_BEATS = [
    {
        "id": "01_hook",
        "t": 1.2,
        "text": "Splitting dinner with friends always starts fun — until the check lands, someone pulls out napkin math, and that one friend swears they will Venmo you tomorrow. But the people sharing tacos and iced lattes? They just want to hang out. So we built Little Wallet, for them.",
        "style": "warm, storytelling, smiling, relatable and humorous human opening"
    },
    {
        "id": "02_say_it",
        "t": 17.5,
        "text": "No forms to fill out. No dropdowns. You just say it. Trader Joe's, eighty-four dollars, split three ways with Sam and Alex. On-device AI listens, figures out what everyone had, calculates the tax, and gives everyone their exact share to the penny. Honestly, it is faster than pulling out a credit card.",
        "style": "cheerful, upbeat, conversational guide, delighted by how simple it is"
    },
    {
        "id": "03_receipt",
        "t": 34.0,
        "text": "Have an actual crumpled paper receipt from the diner? Just snap a photo. The vision model reads through the coffee stains and messy print, pulls out every line item, and lets you drag and drop burgers and fries right onto your friends' avatars.",
        "style": "playful, warm, amused by the crumpled paper, visual and concrete"
    },
    {
        "id": "04_settle_up",
        "t": 48.5,
        "text": "Now, the part where group chats usually go to die: actually getting paid back. With Little Wallet, your friends do not even need to download the app. You just tap share. They get a link that opens right to PayPal or Venmo, they tap once, and the money goes straight to your account.",
        "style": "witty, conversational, relieved, celebrating frictionless PayPal links"
    },
    {
        "id": "05_live_sync",
        "t": 64.0,
        "text": "And here is our favorite little detail: the second Sam taps pay on PayPal, his badge on your phone flips from Waiting to Paid instantly. Live webhooks. No refreshing, no awkward texts asking 'Hey, did it go through?' It just knows.",
        "style": "clever, delighted, sharing our favorite magic detail"
    },
    {
        "id": "06_penny_agent",
        "t": 77.5,
        "text": "And if someone still forgets? Meet Penny. Penny is our AI financial agent. If Alex owes you for last week's groceries, Penny drafts an official PayPal Invoice so it does not feel awkward. Overcharged someone? Penny prepares an instant PayPal Refund. Need to reimburse three roommates for utilities? Penny batches a PayPal Payout in a single tap. She never touches your money without your confirmation.",
        "style": "smart, friendly, confident companion showing off Penny's superpowers"
    },
    {
        "id": "07_close",
        "t": 98.0,
        "text": "No spreadsheets. No calculators. No chasing your friends. Just your spending, handled. Little Wallet. Imagine it. Build what is next with PayPal and AI.",
        "style": "warm, sunny, inspiring, triumphant final sign-off"
    }
]

def find_audio(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("data", "audio_content", "audioContent") and isinstance(v, str) and len(v) > 200:
                return v
            res = find_audio(v)
            if res: return res
    elif isinstance(obj, list):
        for item in obj:
            res = find_audio(item)
            if res: return res
    return None

def synthesize_clip(text, style, dest_path, retries=8):
    payload = {
        "model": "gemini-3.8-flash-tts",
        "input": [{
            "type": "user_input",
            "content": [{
                "type": "text",
                "text": text,
                "annotations": [{
                    "type": "speech_metadata",
                    "style": style
                }]
            }]
        }],
        "response_format": {"type": "audio"},
        "generation_config": {
            "speech_config": [
                {"voice": "Autonoe"}
            ]
        }
    }
    
    data_bytes = json.dumps(payload).encode("utf-8")
    url = f"https://generativelanguage.googleapis.com/v1beta/interactions?key={API_KEY}"
    
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=data_bytes, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req) as resp:
                result = json.loads(resp.read().decode("utf-8"))
                b64 = find_audio(result)
                if b64:
                    with open(dest_path, "wb") as f:
                        f.write(base64.b64decode(b64))
                    return True
        except urllib.error.HTTPError as e:
            if e.code == 429:
                print(f"  ⏳ [429 Rate Limit] Pacing required. Waiting 35s (attempt {attempt+1}/{retries})...")
                time.sleep(35)
                continue
            print(f"  [Attempt {attempt+1}] HTTP Error: {e}")
            time.sleep(5)
        except Exception as e:
            print(f"  [Attempt {attempt+1}] Error: {e}")
            time.sleep(5)
    return False

def read_wav(path):
    with wave.open(path) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        if w.getnchannels() == 2:
            a = a.reshape(-1, 2).mean(1)
        assert w.getframerate() == SR, f"{path} rate mismatch: {w.getframerate()}"
    return a

def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)

def adsr(n, a, d, s, r, sr=SR):
    env = np.ones(n) * s
    A, D, R = int(a * sr), int(d * sr), int(r * sr)
    A = min(A, n); env[:A] = np.linspace(0, 1, A)
    D = min(D, n - A); env[A:A + D] = np.linspace(1, s, D)
    R = min(R, n); env[n - R:] *= np.linspace(1, 0, R)
    return env

def place(buf, sig, t, gain=1.0):
    i = int(t * SR)
    if i >= len(buf): return
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[:j - i] * gain

def bell(f, dur=1.4, bright=0.4):
    n = int(dur * SR); tt = np.arange(n) / SR
    return (np.sin(2 * np.pi * f * tt) + bright * np.sin(2 * np.pi * 2.76 * f * tt) * np.exp(-tt * 6)) * np.exp(-tt * 3.2)

def chime_success(sfx, t):
    for i, m in enumerate((76, 81, 83, 88)):
        place(sfx, bell(midi(m), 1.2, 0.3) * 0.35, t + i * 0.08)

def pop_click(sfx, t, f=720, gain=0.25):
    n = int(0.2 * SR); tt = np.arange(n) / SR
    fr = f * (1 + 0.5 * np.exp(-tt * 40))
    place(sfx, np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-tt * 20) * gain, t)

def whoosh(sfx, t, dur=0.6, gain=0.15):
    n = int(dur * SR); tt = np.arange(n) / SR
    w = rng.standard_normal(n)
    cut = 350 + 2800 * np.sin(np.pi * tt / dur) ** 2
    y = np.zeros(n); a = 0.0
    for i in range(n):
        al = 1 - np.exp(-2 * np.pi * cut[i] / SR); a += al * (w[i] - a); y[i] = a
    place(sfx, y * np.sin(np.pi * tt / dur) ** 1.5 * gain, t - dur * 0.5)

def main():
    print("==================================================================")
    print("🎬 Step 1: Synthesizing Little Wallet Story with Autonoe (Gemini 3.8 Flash TTS)")
    print("==================================================================")
    
    vo_norm_dir = os.path.join(STEMS_DIR, "norm")
    os.makedirs(vo_norm_dir, exist_ok=True)
    vo = np.zeros(N, np.float32)
    
    for i, item in enumerate(STORY_BEATS):
        name = item["id"]
        raw_path = os.path.join(STEMS_DIR, f"{name}.wav")
        norm_path = os.path.join(vo_norm_dir, f"{name}.wav")
        
        print(f"\n▶️  [Beat {i+1}/{len(STORY_BEATS)}] {name} (Cue: {item['t']}s)")
        if not os.path.exists(raw_path) or os.path.getsize(raw_path) < 1000:
            print(f"   Synthesizing: \"{item['text'][:60]}...\"")
            ok = synthesize_clip(item["text"], item["style"], raw_path)
            if not ok:
                raise RuntimeError(f"Failed to synthesize {name}")
            print(f"   ✅ Done ({os.path.getsize(raw_path) // 1024} KB)")
            if i < len(STORY_BEATS) - 1:
                print("   ⏳ Pacing 32s before next beat to stay comfortably within rate limit...")
                time.sleep(32)
        else:
            print(f"   ⚡ Already cached, reusing.")
            
        subprocess.run([
            "ffmpeg", "-v", "error", "-y", "-i", raw_path,
            "-af", "highpass=f=70,loudnorm=I=-17:TP=-1.5:LRA=11,aresample=48000",
            "-ac", "1", "-ar", str(SR), norm_path
        ], check=True)
        
        place(vo, read_wav(norm_path), item["t"])

    print("\n==================================================================")
    print("🎵 Step 2: Generating 3D-Craft Style Musical Score & Delightful SFX")
    print("==================================================================")
    
    BPM = 94.0
    beat = 60 / BPM
    bar = 4 * beat
    
    # Warm, friendly chords (Fmaj7 -> Dm9 -> Bbmaj7 -> C6/9)
    CHORDS = [
        (41, [53, 57, 60, 64]),      # Fmaj7
        (38, [50, 53, 57, 60, 64]),  # Dm9
        (46, [50, 53, 57, 62]),      # Bbmaj7
        (48, [52, 55, 60, 62]),      # C6/9
    ]
    t_axis = np.arange(N) / SR
    pad = np.zeros(N, np.float32)
    arp = np.zeros(N, np.float32)
    bass = np.zeros(N, np.float32)
    hats = np.zeros(N, np.float32)

    def energy(t):
        if t < 0.8: return 0.0
        if t < 2.5: return (t - 0.8) / 1.7
        if t < 103.0: return 1.0
        return max(0.0, 1.0 - (t - 103.0) / 4.0)

    chord_len = 2 * bar
    n_chords = int(np.ceil(DUR / chord_len)) + 1
    for k in range(n_chords):
        t0 = k * chord_len
        b, tones = CHORDS[k % 4]
        if t0 > DUR: break
        n = int((chord_len + 1.6) * SR)
        tt = np.arange(n) / SR
        env = adsr(n, 1.0, 0.4, 0.85, 1.5)
        sig = np.zeros(n, np.float32)
        for m in tones:
            f = midi(m + 12 if m < 52 else m)
            for det in (-0.12, 0.12):
                ph = 2 * np.pi * f * (1 + det / 100) * tt
                sig += (np.sin(ph) + 0.18 * np.sin(2 * ph)) * 0.5
        sig *= env / len(tones)
        place(pad, sig * (0.85 + 0.15 * np.sin(k)), t0)
        
        for bb in range(2):
            tb = t0 + bb * bar
            e = energy(tb)
            if e <= 0: continue
            nb = int(bar * SR); tb_ = np.arange(nb) / SR
            env_b = np.exp(-tb_ * 1.8) * adsr(nb, 0.01, 0.1, 1, 0.3)
            f = midi(b - 12 + 12)
            place(bass, (np.sin(2 * np.pi * f * tb_) + 0.25 * np.sin(4 * np.pi * f * tb_)) * env_b * e, tb)
            
        pattern = [0, 2, 1, 3, 2, 0, 1, 2]
        ups = sorted(set(m + 12 for m in tones))
        for s8 in range(16):
            te = t0 + s8 * beat / 2
            if te > DUR: break
            e = energy(te)
            intro = 1.0 if te < 10.0 and s8 % 2 == 0 else 0.0
            amp = max(e, intro * 0.75)
            if amp <= 0: continue
            m = ups[pattern[s8 % 8] % len(ups)]
            f = midi(m)
            nn = int(1.1 * SR); tn = np.arange(nn) / SR
            env_n = np.exp(-tn * 4.5)
            tone = np.sin(2 * np.pi * f * tn) + 0.3 * np.sin(2 * np.pi * 2 * f * tn) * np.exp(-tn * 8)
            vel = 0.75 + 0.25 * ((s8 * 3) % 4) / 3
            place(arp, tone * env_n * amp * vel, te)
            
        for s8 in range(16):
            te = t0 + s8 * beat / 2 + beat / 4
            e = energy(te)
            if e <= 0 or te > DUR: continue
            nh = int(0.08 * SR)
            noise = rng.standard_normal(nh)
            noise = np.diff(np.concatenate([[0], noise]))
            place(hats, noise * np.exp(-np.arange(nh) / SR * 60) * e * (0.5 if s8 % 2 else 0.3), te)

    music = 0.35 * pad + 0.20 * arp + 0.32 * bass + 0.06 * hats
    
    # Tactile and delightful sound effects matching Little Wallet moments
    sfx = np.zeros(N, np.float32)
    # Opening whoosh into the story
    whoosh(sfx, 1.0, 0.7, 0.18)
    # Voice "Say it" microphone pop
    pop_click(sfx, 17.4, 880, 0.3)
    # Receipt scan camera tick
    for i in range(3): pop_click(sfx, 34.2 + i * 0.12, 1200 + i * 200, 0.15)
    # Settle-up share link whoosh
    whoosh(sfx, 48.3, 0.5, 0.15)
    # Instant PayPal Paid chime!
    chime_success(sfx, 65.5)
    # Penny Agent smart badge
    pop_click(sfx, 77.2, 950, 0.3)
    # Ending celebratory chime
    chime_success(sfx, 102.5)

    print("\n==================================================================")
    print("🎛️  Step 3: Dynamic Voice Ducking & Broadcast Mastering (-14 LUFS)")
    print("==================================================================")
    
    env_v = np.abs(vo)
    win = int(0.05 * SR)
    env_v = np.convolve(env_v, np.ones(win) / win, 'same')
    active = (env_v > 0.01).astype(np.float32)
    duck = np.zeros_like(active); g = 0.0
    att, rel = 1 - np.exp(-1 / (0.15 * SR)), 1 - np.exp(-1 / (0.45 * SR))
    for i in range(0, N, 16):
        target = active[i]
        g += (att if target > g else rel) * 16 * (target - g)
        duck[i:i + 16] = g
        
    music_gain = 10 ** (-13 / 20) * (1 - 0.58 * duck)
    fade = np.clip((DUR - t_axis) / 3.0, 0, 1) * np.clip(t_axis / 0.5, 0, 1)
    
    master = vo + music * music_gain * 1.5 + sfx * 0.85
    master *= fade
    
    # Stereo widening
    stereo = np.stack([master, master], 1)
    width = (music * music_gain * 1.5 + sfx * 0.85) * fade
    d = int(0.012 * SR)
    stereo[d:, 1] += 0.18 * width[:-d]
    pk = np.abs(stereo).max()
    stereo /= max(1.0, pk / 0.95)
    
    raw_wav = os.path.join(AUDIO_DIR, "little_wallet_story_mix_raw.wav")
    with wave.open(raw_wav, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(stereo, -1, 1) * 32767).astype(np.int16).tobytes())
        
    final_master_wav = os.path.join(AUDIO_DIR, "little_wallet_story_master_autonoe.wav")
    final_master_mp3 = os.path.join(AUDIO_DIR, "little_wallet_story_master_autonoe.mp3")
    
    subprocess.run([
        "ffmpeg", "-v", "error", "-y", "-i", raw_wav,
        "-af", "loudnorm=I=-14:TP=-1.0:LRA=11,alimiter=limit=0.95,aresample=48000",
        "-ar", str(SR), final_master_wav
    ], check=True)
    subprocess.run([
        "ffmpeg", "-v", "error", "-y", "-i", final_master_wav,
        "-b:a", "256k", final_master_mp3
    ], check=True)
    
    # Also export pure voice track
    pure_voice_mp3 = os.path.join(AUDIO_DIR, "little_wallet_story_pure_voice_autonoe.mp3")
    pure_wav = os.path.join(AUDIO_DIR, "little_wallet_story_pure_voice_autonoe.wav")
    with wave.open(pure_wav, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(vo * fade, -1, 1) * 32767).astype(np.int16).tobytes())
    subprocess.run([
        "ffmpeg", "-v", "error", "-y", "-i", pure_wav,
        "-b:a", "192k", pure_voice_mp3
    ], check=True)
    
    print("\n==================================================================")
    print(f"🎉 MASTER STORY AUDIO COMPLETED!")
    print(f"--> Master Broadcast (Autonoe + 3D Craft Groove): {final_master_mp3}")
    print(f"--> Pure Voiceover: {pure_voice_mp3}")
    print("==================================================================")

if __name__ == "__main__":
    main()
