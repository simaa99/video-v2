# 🎥 Video v2 - HLS Video Streaming Repository

The central asset repository for high-performance HLS (HTTP Live Streaming) and MP4 video delivery across the **Franc Vila** and **Badreya** web platforms.

<div align="center">
  <img src="https://img.shields.io/badge/FFmpeg-Ready-0078D4?style=for-the-badge&logo=ffmpeg&logoColor=white" alt="FFmpeg Ready" />
  <img src="https://img.shields.io/badge/GitHub%20Pages-Hosted-222222?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Pages Hosted" />
  <img src="https://img.shields.io/badge/HLS-Adaptive%20Streaming-orange?style=for-the-badge" alt="HLS Adaptive Streaming" />
</div>

---

## 📖 Table of Contents
- [🔍 Overview](#-overview)
- [⚡ Why HLS (HTTP Live Streaming)?](#-why-hls-http-live-streaming)
- [📂 Repository Structure](#-repository-structure)
- [⚙️ Prerequisites](#️-prerequisites)
- [🚀 How to Convert Videos](#-how-to-convert-videos)
- [🛠️ How the Conversion Script Works](#️-how-the-conversion-script-works)
- [🔗 URL Structure & Hosting](#-url-structure--hosting)
- [💻 React & Next.js Integration](#-react--nextjs-integration)
- [📋 Developer Workflow](#-developer-workflow)

---

## 🔍 Overview

This repository acts as the media hosting and processing backend for **Badreya** and **Franc Vila** web platforms. Instead of serving massive static `.mp4` files directly—which delays page rendering, causes buffering, and consumes excessive mobile data—videos are processed into **HLS (HTTP Live Streaming)** directories. This allows the websites to serve fast, modern, and adaptive video streams tailored directly to each user's network connection.

---

## ⚡ Why HLS (HTTP Live Streaming)?

1. **Adaptive Bitrate Streaming:** The player automatically shifts between 1080p (high fidelity) and 480p (lighter weight) depending on the user's internet speed, ensuring zero buffer lags.
2. **Instant Playback (Fast Start):** The video is split into small chunks (6 seconds each). The browser only needs to download the first segment to start playing, resulting in an instant-on user experience.
3. **Broad Native Compatibility:** Works natively on Safari and iOS devices, and seamlessly on Chrome, Firefox, and Edge via standard integration libraries (such as `hls.js`).

---

## 📂 Repository Structure

```directory
video-v2/
├── sources/                     # Raw MP4 masters (git-ignored, see .gitignore)
│   ├── fin3.mp4
│   └── don-blue.mp4
├── scripts/
│   ├── convert_hls.sh           # 🛠️ HLS conversion script (1080p/720p/480p ladder + poster)
│   ├── validate_hls.sh          # QA gate: segments, playlists, posters, ABR alignment
│   └── cleanup.sh               # Finds stray/orphaned video files (dry-run by default)
├── tools/
│   └── test-player.html         # hls.js QA harness: paste a master.m3u8 URL to test
├── deploy/
│   ├── nginx.hls.conf.example    # MIME types + cache headers if self-hosting/CDN origin
│   └── _headers                  # Same, for Cloudflare Pages / Netlify
├── .github/workflows/transcode.yml  # Manual CI transcode (stopgap, see file header)
└── hls/                          # HLS output ONLY — nothing else belongs here
    ├── fin3/
    │   ├── master.m3u8
    │   ├── poster.jpg
    │   ├── 720p/{index.m3u8, segment_000.ts, ...}
    │   └── 480p/{index.m3u8, segment_000.ts, ...}
    └── ...
```

See `docs/hls-migration-review.md` (or the shared artifact) for the full architecture review this structure is based on.

---

## ⚙️ Prerequisites

To run the local conversion script on your machine, you need **FFmpeg** and **FFprobe** installed:

```bash
# Install FFmpeg using Homebrew on macOS
brew install ffmpeg
```

Verify that the utilities are installed correctly by running:
```bash
ffmpeg -version
ffprobe -version
```

---

## 🚀 How to Convert Videos

Follow these steps to convert any standard `.mp4` video file into an HLS adaptive streaming bundle:

### 1️⃣ Place the source file
Put the raw MP4 in `sources/` (this folder is git-ignored — see `.gitignore`).

### 2️⃣ Run the conversion script from the repo root
```bash
./scripts/convert_hls.sh sources/<input_file> <slug> [--presets=1080p,720p,480p] [--force]
```

#### 💡 Commands & Examples:
* **Convert `fin3.mp4` with the default 1080p/720p/480p ladder:**
  ```bash
  ./scripts/convert_hls.sh sources/fin3.mp4 fin3
  ```
* **Only generate 720p and 480p (e.g. a video that's already small):**
  ```bash
  ./scripts/convert_hls.sh sources/ring.MP4 ring --presets=720p,480p
  ```
* **Re-run and overwrite an existing hls/<slug> without the confirmation prompt:**
  ```bash
  ./scripts/convert_hls.sh sources/fin3.mp4 fin3 --force
  ```

The script skips any rung above the source's native resolution (never upscales), forces
keyframes at exact 6-second boundaries so every rendition cuts identically, writes a
`poster.jpg` thumbnail alongside `master.m3u8`, and **self-validates its own output**
via `scripts/validate_hls.sh` before exiting — if validation fails, the script exits
non-zero and does not report success.

### 3️⃣ Check for stray files
```bash
./scripts/cleanup.sh          # dry run — lists problems
./scripts/cleanup.sh --force  # moves stray hls/*.mp4 files into sources/
```

### 4️⃣ QA the result locally
```bash
python3 -m http.server 8000
open tools/test-player.html   # paste http://localhost:8000/hls/<slug>/master.m3u8
```

---

## 🛠️ How the Conversion Script Works

The `convert_hls.sh` script automates the transcoding pipeline:

1. **Resolution & Bitrate Ladder:** Encodes up to four capped-CRF renditions — `1080p` (~5000kbps), `720p` (~2800kbps), `480p` (~1400kbps), `360p` (~800kbps) — skipping any rung above the source's native resolution.
2. **Chunk Segmentation:** Cuts every rendition into independent **6-second segments** (`segment_NNN.ts`), with keyframes forced at exact segment boundaries so every rendition cuts at identical timestamps (required for clean ABR switching).
3. **Thumbnail:** Extracts a `poster.jpg` at ~10% into the video.
4. **Master Playlist Generation (`master.m3u8`):** Computes bandwidth/resolution per rung from the source's probed dimensions, **reads the actual encoded profile/level back from `ffprobe`** to build an accurate `CODECS` string per rung (no hardcoded guess), and writes a standards-compliant multi-variant playlist with `#EXT-X-INDEPENDENT-SEGMENTS`.
5. **Self-Validation:** Runs `scripts/validate_hls.sh` against its own output before exiting — checks every playlist, every segment's existence and decodability, poster validity, and that all renditions of a video have matching segment counts (the precondition for clean ABR switching). A failed validation makes the script exit non-zero, so a bad encode never gets treated as done, locally or in CI.

---

## 🔗 URL Structure & Hosting

This repository is hosted on **GitHub Pages**, serving files directly as a static content delivery network (CDN):

* **GitHub Repository:** `https://github.com/simaa99/video-v2`
* **Static Content Base URL:** `https://simaa99.github.io/video-v2/`

### 📌 Live Stream URL Pattern:
To play or stream any converted video in your code, target the folder's `master.m3u8` playlist using this structure:
```text
https://simaa99.github.io/video-v2/hls/<folder_name>/master.m3u8
```

> Folder names match the slugs under `hls/` (see [Repository Structure](#-repository-structure)).

---

## 💻 React & Next.js Integration

To play adaptive HLS streams smoothly in your web apps, we recommend implementing a custom video component utilizing `hls.js` for non-native browsers, and native fallback for Apple devices.

Here is a ready-to-use, optimized React component:

```tsx
"use client";

import { useEffect, useRef } from "react";
import Hls from "hls.js";

interface HlsVideoPlayerProps {
  src: string;        // Path to the master.m3u8 file
  poster?: string;    // Image shown before the video starts
  className?: string;
  autoPlay?: boolean;
  muted?: boolean;
  loop?: boolean;
  onFatalError?: (message: string) => void; // e.g. show a fallback UI
}

const MAX_ERROR_RETRIES = 3;

export default function HlsVideoPlayer({
  src,
  poster,
  className = "",
  autoPlay = true,
  muted = true,
  loop = true,
  onFatalError,
}: HlsVideoPlayerProps) {
  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    let hls: Hls | null = null;
    let retryCount = 0;

    const play = () => {
      if (autoPlay) video.play().catch((err) => console.log("Autoplay was blocked:", err));
    };

    if (Hls.isSupported()) {
      // For browsers without native HLS support (Chrome, Firefox, Edge, etc.)
      hls = new Hls({
        maxMaxBufferLength: 30, // Buffers up to 30 seconds ahead for fluid playback
      });
      hls.loadSource(src);
      hls.attachMedia(video);

      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        retryCount = 0; // reset once a manifest has loaded successfully
        play();
      });

      // Non-fatal errors (a dropped segment fetch, a buffer stall) are
      // recovered from internally by hls.js and don't need our intervention.
      // Fatal errors need an explicit recovery strategy or the player is
      // left permanently frozen/black with no feedback to the user.
      hls.on(Hls.Events.ERROR, (_event, data) => {
        if (!data.fatal) return;

        if (retryCount >= MAX_ERROR_RETRIES) {
          console.error(`HLS fatal error, giving up after ${MAX_ERROR_RETRIES} retries:`, data.type, data.details);
          hls?.destroy();
          onFatalError?.(`Playback failed after ${MAX_ERROR_RETRIES} retries: ${data.details}`);
          return;
        }

        switch (data.type) {
          case Hls.ErrorTypes.NETWORK_ERROR:
            retryCount += 1;
            console.warn(`HLS network error (attempt ${retryCount}/${MAX_ERROR_RETRIES}), retrying:`, data.details);
            // Backs off slightly on each retry instead of hammering a segment
            // that's 404ing because a re-encode is still mid-flight.
            setTimeout(() => hls?.startLoad(), 1000 * retryCount);
            break;
          case Hls.ErrorTypes.MEDIA_ERROR:
            retryCount += 1;
            console.warn(`HLS media error (attempt ${retryCount}/${MAX_ERROR_RETRIES}), attempting recovery:`, data.details);
            hls?.recoverMediaError();
            break;
          default:
            console.error("Unrecoverable HLS error, destroying instance:", data.type, data.details);
            hls?.destroy();
            onFatalError?.(`Unrecoverable playback error: ${data.details}`);
            break;
        }
      });
    } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
      // For browsers with native HLS support (Safari on macOS, iOS devices)
      video.src = src;
      video.addEventListener("loadedmetadata", play);
      // Safari's native player surfaces fatal errors via the <video> element
      // itself rather than hls.js -- there's no retry primitive to call here,
      // but we still want visibility instead of a silently frozen player.
      video.addEventListener("error", () => {
        const err = video.error;
        console.error("Native HLS playback error:", err?.code, err?.message);
        onFatalError?.(`Native playback error (code ${err?.code ?? "unknown"})`);
      });
    }

    return () => {
      // Prevent memory leaks by destroying the HLS instance on component unmount
      if (hls) {
        hls.destroy();
      }
    };
  }, [src, autoPlay, onFatalError]);

  return (
    <video
      ref={videoRef}
      poster={poster}
      className={`w-full h-full object-cover ${className}`}
      muted={muted}
      loop={loop}
      playsInline
      controls
    />
  );
}
```

**Error handling notes:**
- **Network errors** (e.g. a segment 404s because a re-encode is mid-flight) retry with a short backoff, up to `MAX_ERROR_RETRIES` times.
- **Media errors** (decode issues) call `hls.recoverMediaError()`, hls.js's built-in recovery path.
- **Other fatal errors**, and any error type after retries are exhausted, destroy the `hls.js` instance and call the optional `onFatalError` callback so the host page can show a fallback UI instead of a silently frozen or black `<video>` element.
- Safari's native path has no `hls.js` retry primitive to call, but still surfaces failures via the `<video>` element's own `error` event so they're not silent there either.

---

## 📋 Developer Workflow

Use this checklist when introducing a new video asset to the system:

- [ ] **1. Transfer Video:** Place the original file in `sources/` (git-ignored — never commit raw masters, see `.gitignore`).
- [ ] **2. Convert Video:** From the repo root:
  ```bash
  ./scripts/convert_hls.sh sources/my-video.mp4 my-video-folder
  ```
- [ ] **3. Inspect Outputs:** `convert_hls.sh` already ran `scripts/validate_hls.sh` automatically (step 2 fails if this doesn't pass), but re-run it manually any time: `./scripts/validate_hls.sh my-video-folder` (or `./scripts/validate_hls.sh --all` to health-check every video in `hls/` at once). Sanity-check playback in `tools/test-player.html` too.
- [ ] **4. Clean up:** Run `./scripts/cleanup.sh` to confirm no stray files were left behind.
- [ ] **5. Push to Git:** Add, commit, and push only the generated `hls/` folder (never `sources/`):
  ```bash
  git add hls/my-video-folder
  git commit -m "feat: add HLS stream for my-video"
  git push origin main
  ```
- [ ] **6. Wait & Verify:** Give GitHub Pages about a minute to complete deployment, then check the livestream URL directly in a player or browser:
  ```text
  https://simaa99.github.io/video-v2/hls/my-video-folder/master.m3u8
  ```
- [ ] **7. Integrate:** Embed the new HLS URL into your target codebase using the `HlsVideoPlayer` component below.

---

<p align="center" style="margin-top: 50px;">
  <sub>Designed with precision to provide the ultimate media streaming experience.</sub>
</p>
