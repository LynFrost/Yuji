# Third-party notices

Yuji uses **ZstdSharp.Port 0.8.8** for streaming Zstandard decompression of Codex `.jsonl.zst` session files.

- Upstream: https://github.com/oleg-st/ZstdSharp
- Package: https://www.nuget.org/packages/ZstdSharp.Port/0.8.8
- License: MIT (see `licenses/ZstdSharp.Port-MIT.txt`)

The pinned assembly is downloaded on first use into the current user's application cache, outside the repository and source-session directories. Normal `.jsonl` builds do not download or load this dependency. No external command-line decompressor is required.
