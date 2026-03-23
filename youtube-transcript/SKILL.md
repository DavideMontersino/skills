---
name: youtube-transcript
description: Fetch the transcript/subtitles of a YouTube video and return it as text. Use when the user shares a YouTube URL or asks for a video's transcript.
user-invocable: true
---

# YouTube Transcript

Fetch transcript/subtitles from a YouTube video. No API key required.

## Arguments

Accepts a YouTube URL or video ID. Examples:

- `https://www.youtube.com/watch?v=dQw4w9WgXcQ`
- `https://youtu.be/dQw4w9WgXcQ`
- `dQw4w9WgXcQ`

Optional language flag: `--lang <code>` (e.g. `--lang it`). Defaults to English.

## Workflow

### 1. Extract video ID

Parse the video ID from the argument. Handle these URL formats:

- `https://www.youtube.com/watch?v=VIDEO_ID`
- `https://youtu.be/VIDEO_ID`
- `https://www.youtube.com/embed/VIDEO_ID`
- `https://youtube.com/shorts/VIDEO_ID`
- Plain video ID (11-char alphanumeric string)

### 2. Ensure youtube-transcript-api is installed

```bash
python3 -c "import youtube_transcript_api" 2>/dev/null || pip3 install youtube-transcript-api
```

### 3. Fetch transcript

Use an inline Python script — more reliable than the CLI for parsing and formatting:

```bash
python3 -c "
from youtube_transcript_api import YouTubeTranscriptApi
import json, sys

video_id = 'VIDEO_ID'
lang = 'LANG'  # e.g. 'en', 'it', 'de'

ytt = YouTubeTranscriptApi()
try:
    transcript = ytt.fetch(video_id, languages=[lang, 'en'])
except Exception:
    # Fall back to any available language
    transcript = ytt.fetch(video_id)

for entry in transcript:
    print(entry.text)
"
```

Replace `VIDEO_ID` and `LANG` with actual values.

### 4. Present the transcript

- Print the plain text transcript to the user
- If the user asked a question about the video, answer it using the transcript content
- If the transcript is very long (>500 lines), summarize key points and offer to show specific sections

## Error Handling

- If no transcript is available: tell the user the video has no subtitles/captions
- If the language is not available: list available languages and retry with the best match
- If the video ID is invalid: ask the user to double-check the URL

## Notes

- Works with manual and auto-generated subtitles
- No YouTube API key or authentication needed
- The `youtube-transcript-api` package scrapes YouTube's transcript endpoint directly
