# Smack 1.1.0 AI agents song for Suno

## Length

Aim for 75 s (the video speeds adjust to the song, 60 to 90 s all work). Suno does not honor lengths, so keep the lyrics to the 16 lines below and end with [End]. If it runs long, use Suno's crop to cut at the outro.

## Title

Replay the Agent

## Style (paste in "Style of Music", under 200 chars)

driving synth-pop, 124 BPM, pulsing analog bass, bright arpeggios, tight drums, anthemic hook, retro-futuristic, female lead with male backing, instrumental intro, 75 seconds

## Lyrics (paste in "Lyrics")

[Intro]
(arpeggio, building)

[Verse 1]
Three agents running in the night
Claude and Codex, OpenCode
Tools are firing, prompts take flight
Who is working? Now you know

[Chorus]
Replay the agent, line by line
Every prompt, every command, every sign
Zoom in close, zoom out wide
Nothing is hiding, the timeline is the guide

[Verse 2]
One failed run, one MCP call
Click the moment, see it all
Read the transcript, nothing's sent
Only on screen, nothing spent

[Chorus]
Replay the agent, line by line
Smack one-point-one, and it's all in time
Zoom in close, zoom out wide
Nothing is hiding, the timeline is the guide

[Outro]
Smack, one-point-one
[End]

## Render

    python3 Scripts/release-video/release-video.py render docs/development/release-video/1.1.0-ai-agents/segments.json ~/Desktop/SmackAIAgents.mov ~/Desktop/Smack-1.1.0-ai-agents.mp4 --song <song.mp3>
